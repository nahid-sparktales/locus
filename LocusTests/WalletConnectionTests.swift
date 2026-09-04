import CryptoKit
import SQLite3
import XCTest
@testable import Locus

@MainActor
final class WalletConnectionTests: XCTestCase {
    func testWalletConnectUsesOfficialSolanaGenesisReferences() throws {
        XCTAssertEqual(
            try WalletConnectDriver.walletConnectNetworkID("solana:devnet"),
            "solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1"
        )
        XCTAssertEqual(
            try WalletConnectDriver.walletConnectNetworkID("solana:mainnet-beta"),
            "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2d"
        )
    }

    func testWalletConnectKeccakMatchesEthereumVectors() {
        XCTAssertEqual(
            WalletKeccak256.hash(Data()).map { String(format: "%02x", $0) }.joined(),
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        )
        XCTAssertEqual(
            WalletKeccak256.hash(Data("abc".utf8)).map {
                String(format: "%02x", $0)
            }.joined(),
            "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45"
        )
    }

    func testReviewedConnectorIdentitiesAreExact() {
        XCTAssertEqual(
            WalletConnectorBuildIdentity.reviewed(.metamask)?.version,
            "2.1.1"
        )
        XCTAssertEqual(
            WalletConnectorBuildIdentity.reviewed(.walletConnect)?.version,
            "2.3.2+locus.1"
        )
        XCTAssertEqual(
            WalletConnectorBuildIdentity.reviewed(.walletConnect)?.artifactSHA256.count,
            64
        )
    }
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testLegacyWalletAccountDecodesAsLocusVaultOwnership() throws {
        let payload = Data(#"""
        {
            "id":"account-1",
            "chain":"evm",
            "address":"0x1111111111111111111111111111111111111111",
            "label":"Account",
            "networkIDs":["eip155:11155111"]
        }
        """#.utf8)

        let account = try JSONDecoder().decode(WalletAccount.self, from: payload)

        XCTAssertEqual(account.ownership, .locusVault)
    }

    func testSwiftSuiNativeReconstructionMatchesAuditedRustVector() throws {
        let sender = "0xf967e21c16a4757daafec13ee79c0dc5c5329199be5d70c86fd07b8e75db892c"
        let recipient = "0x" + String(repeating: "07", count: 32)
        let action = WalletSemanticAction.nativeTransfer(
            recipient: recipient, amountBaseUnits: "123456789"
        )
        let request = WalletPrepareRequest(
            networkID: "sui:mainnet", accountID: "sui-account",
            source: .human, action: action,
            maximumFeeBaseUnits: "10000000"
        )
        let packet = WalletSuiPreparationPacket(
            request: request, chainIdentifier: WalletSuiChainIdentity.mainnetBase58,
            checkpointSequence: 1, checkpointTimestamp: now,
            sender: sender, assetID: "sui:mainnet/coin:0x2::sui::SUI",
            coinType: WalletSuiAssetIdentity.nativeCoinType,
            coinObject: nil, coinBalanceBaseUnits: nil,
            coinCheckpointSequence: nil, coinCheckpointTimestamp: nil,
            transferredObject: nil, objectHasPublicTransfer: nil,
            objectCheckpointSequence: nil, objectCheckpointTimestamp: nil,
            gasObject: WalletSuiObjectReference(
                objectID: "0x" + String(repeating: "08", count: 32),
                version: 42,
                digest: WalletSolanaBase58.encode(Data(repeating: 9, count: 32)),
                type: "0x2::coin::Coin<0x2::sui::SUI>"
            ),
            gasBalanceBaseUnits: "5000000000",
            gasBudgetBaseUnits: "10000000",
            referenceGasPriceBaseUnits: "1000",
            gasPriceBaseUnits: "1000", currentEpoch: 412,
            expirationEpoch: 412, observedAt: now
        )

        let rebuilt = try WalletSuiCanonicalTransaction(packet: packet)

        XCTAssertEqual(
            rebuilt.transactionBCS.base64EncodedString(),
            "AAACAAgVzVsHAAAAAAAgBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcCAgABAQAAAQEDAAAAAAEBAPln4hwWpHV9qv7BPuecDcXFMpGZvl1wyG/Qe45124ksAQgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIKgAAAAAAAAAgCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQn5Z+IcFqR1far+wT7nnA3FxTKRmb5dcMhv0HuOdduJLOgDAAAAAAAAgJaYAAAAAAABnAEAAAAAAAA="
        )
        XCTAssertEqual(rebuilt.transactionDigest, "UWx2nPyFTrBo7AFnv46gHJthCkfERY5ash86HcnSdpC")
        XCTAssertEqual(
            rebuilt.signingDigest,
            "blake2b256:ea728848d79bf40086a665575c973e09ad816617602133decbf6240412bb4cee"
        )
    }

    func testExternalAccountOwnershipRoundTripsWithoutSessionMaterial() throws {
        let account = WalletAccount(
            id: "metamask:0x1111111111111111111111111111111111111111",
            chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "MetaMask",
            networkIDs: ["eip155:11155111"],
            ownership: .external(connectorID: .metamask)
        )

        let encoded = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(WalletAccount.self, from: encoded), account)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("secret"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("signature"))
    }

    func testConnectorManagedPhantomOwnershipRoundTripsAndRequiresManagedConnection() throws {
        let account = WalletAccount(
            id: "phantom:11111111111111111111111111111111",
            chain: .solana,
            address: "11111111111111111111111111111111",
            label: "Phantom-managed",
            networkIDs: ["solana:devnet"],
            ownership: .connectorManaged(connectorID: .phantom)
        )
        let connection = WalletConnectionRecord(
            id: "phantom-connection", direction: .externalAccountToLocus,
            connector: .phantom,
            accountOwnership: .connectorManaged(connectorID: .phantom),
            peerName: "Phantom-managed", peerURL: nil,
            networkIDs: ["solana:devnet"],
            approvedMethods: [.listAccounts, .sendTransaction, .signInWithSolana],
            accountIDs: [account.id], state: .connected,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(60)
        )
        let binding = WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000091",
            connectionID: connection.id, direction: connection.direction,
            connector: connection.connector, origin: nil, peerID: nil,
            accountID: account.id, networkID: "solana:devnet",
            method: .sendTransaction, issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30)
        )

        let encoded = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(WalletAccount.self, from: encoded), account)
        XCTAssertTrue(account.ownership.isConnectorManaged)
        XCTAssertFalse(account.ownership.requiresWalletOwnedConfirmation)
        XCTAssertNoThrow(try WalletConnectionAuthority.validate(
            binding, against: connection, now: now
        ))

        let legacyExternal = WalletConnectionRecord(
            id: connection.id, direction: connection.direction,
            connector: connection.connector,
            accountOwnership: .external(connectorID: .phantom),
            peerName: connection.peerName, peerURL: nil,
            networkIDs: connection.networkIDs,
            approvedMethods: connection.approvedMethods,
            accountIDs: connection.accountIDs, state: .connected,
            createdAt: connection.createdAt, updatedAt: connection.updatedAt,
            expiresAt: connection.expiresAt
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            binding, against: legacyExternal, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .directionMismatch) }
    }

    func testSchemaV2ConnectionPersistsOnlyPublicLifecycleMetadata() throws {
        let store = try WalletPublicStore(path: ":memory:")
        let connection = makeConnection()

        try store.upsertConnection(connection)

        XCTAssertEqual(try store.loadConnections(), [connection])
        XCTAssertEqual(WalletPublicStore.schemaVersion, 2)
    }

    func testSchemaV1DatabaseMigratesAndDecodesLegacyConnection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "locus-wallet-migration-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("wallet.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let legacy = #"{"id":"legacy-1","kind":"browser","peerName":"Example","peerURL":"https://app.example","networkIDs":["eip155:11155111"],"methods":["list_accounts","send_transaction"],"accountIDs":["account-1"],"createdAt":"2033-05-18T03:32:20Z","expiresAt":"2033-05-18T03:42:20Z","disconnectedAt":null}"#
        let blob = Data(legacy.utf8).map { String(format: "%02x", $0) }.joined()
        let setup = """
        CREATE TABLE wallet_schema (version INTEGER NOT NULL);
        INSERT INTO wallet_schema(version) VALUES(1);
        CREATE TABLE connections (
            id TEXT PRIMARY KEY, network_id TEXT NOT NULL,
            peer_name TEXT NOT NULL, updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        );
        INSERT INTO connections(id, network_id, peer_name, updated_at, payload)
        VALUES('legacy-1', 'eip155:11155111', 'Example', 2000000000, X'\(blob)');
        """
        XCTAssertEqual(sqlite3_exec(database, setup, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let migrated = try WalletPublicStore(url: databaseURL)
        let records = try migrated.loadConnections()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].connector, .embeddedBrowser)
        XCTAssertEqual(records[0].direction, .locusVaultToDapp)
        XCTAssertEqual(records[0].state, .connected)
        XCTAssertEqual(records[0].accountOwnership, .locusVault)
        XCTAssertEqual(records[0].approvedMethods, [.listAccounts, .sendTransaction])
        XCTAssertNil(records[0].peerID)
    }

    func testConnectionAuthorityRejectsOriginAccountNetworkAndCallbackSubstitution() throws {
        let connection = makeConnection()
        let binding = makeBinding(connection: connection)
        XCTAssertNoThrow(try WalletConnectionAuthority.validate(
            binding, against: connection, now: now
        ))

        let wrongAccount = WalletConnectionRequestBinding(
            requestID: binding.requestID, connectionID: binding.connectionID,
            direction: binding.direction, connector: binding.connector,
            origin: binding.origin, peerID: binding.peerID, accountID: "attacker",
            networkID: binding.networkID, method: binding.method,
            issuedAt: binding.issuedAt, expiresAt: binding.expiresAt
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            wrongAccount, against: connection, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .accountNotApproved) }

        let wrongNetwork = WalletConnectionRequestBinding(
            requestID: binding.requestID, connectionID: binding.connectionID,
            direction: binding.direction, connector: binding.connector,
            origin: binding.origin, peerID: binding.peerID, accountID: binding.accountID,
            networkID: "eip155:1", method: binding.method,
            issuedAt: binding.issuedAt, expiresAt: binding.expiresAt
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            wrongNetwork, against: connection, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .networkNotApproved) }

        let wrongOrigin = WalletConnectionRequestBinding(
            requestID: binding.requestID, connectionID: binding.connectionID,
            direction: binding.direction, connector: binding.connector,
            origin: "https://attacker.example", peerID: binding.peerID,
            accountID: binding.accountID, networkID: binding.networkID,
            method: binding.method, issuedAt: binding.issuedAt,
            expiresAt: binding.expiresAt
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validateCallback(
            expected: binding, received: wrongOrigin, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .bindingMismatch) }
    }

    func testConnectionAuthorityRejectsStaleRevokedAndDirectionMismatch() throws {
        let connection = makeConnection()
        let binding = makeBinding(connection: connection)
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            binding, against: connection, now: binding.expiresAt
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .stale) }

        let outlivesConnection = WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000009",
            connectionID: binding.connectionID, direction: binding.direction,
            connector: binding.connector, origin: binding.origin,
            peerID: binding.peerID, accountID: binding.accountID,
            networkID: binding.networkID, method: binding.method,
            issuedAt: binding.issuedAt, expiresAt: connection.expiresAt.addingTimeInterval(1)
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            outlivesConnection, against: connection, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .stale) }

        let revoked = try XCTUnwrap(connection.transitioning(
            to: .revoked, at: now.addingTimeInterval(1)
        ))
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            binding, against: revoked, now: now.addingTimeInterval(2)
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .disconnected) }

        let invalidDirection = WalletConnectionRecord(
            id: connection.id, direction: .locusVaultToDapp,
            connector: .metamask, peerName: connection.peerName,
            peerURL: connection.peerURL, networkIDs: connection.networkIDs,
            approvedMethods: connection.approvedMethods,
            accountIDs: connection.accountIDs, state: .connected,
            createdAt: connection.createdAt, updatedAt: connection.updatedAt,
            expiresAt: connection.expiresAt
        )
        let invalidBinding = WalletConnectionRequestBinding(
            requestID: binding.requestID, connectionID: binding.connectionID,
            direction: .locusVaultToDapp, connector: binding.connector,
            origin: binding.origin, peerID: binding.peerID,
            accountID: binding.accountID, networkID: binding.networkID,
            method: binding.method, issuedAt: binding.issuedAt,
            expiresAt: binding.expiresAt
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            invalidBinding, against: invalidDirection, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .directionMismatch) }
    }

    func testConnectionAuthorityBindsBrowserOriginAndWalletConnectPeer() throws {
        let browserConnection = WalletConnectionRecord(
            id: "browser-1", direction: .locusVaultToDapp,
            connector: .embeddedBrowser, peerName: "Example",
            peerURL: "https://app.example", networkIDs: ["eip155:11155111"],
            approvedMethods: [.sendTransaction], accountIDs: ["account-1"],
            state: .connected, createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600)
        )
        let browserBinding = WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000003",
            connectionID: browserConnection.id, direction: .locusVaultToDapp,
            connector: .embeddedBrowser, origin: "https://attacker.example",
            peerID: nil, accountID: "account-1", networkID: "eip155:11155111",
            method: .sendTransaction, issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            browserBinding, against: browserConnection, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .bindingMismatch) }

        let walletConnect = WalletConnectionRecord(
            id: "wc-1", direction: .locusVaultToDapp,
            connector: .walletConnect, peerName: "Example dapp", peerURL: nil,
            peerID: "peer-a", networkIDs: ["solana:devnet"],
            approvedMethods: [.sendTransaction], accountIDs: ["account-2"],
            state: .connected, createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600)
        )
        let peerBinding = WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000004",
            connectionID: walletConnect.id, direction: .locusVaultToDapp,
            connector: .walletConnect, origin: nil, peerID: "peer-b",
            accountID: "account-2", networkID: "solana:devnet",
            method: .sendTransaction, issuedAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        XCTAssertThrowsError(try WalletConnectionAuthority.validate(
            peerBinding, against: walletConnect, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .bindingMismatch) }
    }

    func testNamespaceValidatorRejectsCrossChainAndUnsupportedSignIn() throws {
        XCTAssertNoThrow(try WalletConnectionNamespaceValidator.validate(
            [.init(
                namespace: .solana,
                networkIDs: ["solana:devnet"],
                methods: [.listAccounts, .sendTransaction, .signInWithSolana],
                events: [.accountsChanged, .networkChanged, .disconnected]
            )],
            connector: .walletConnect,
            direction: .locusVaultToDapp
        ))
        XCTAssertThrowsError(try WalletConnectionNamespaceValidator.validate(
            [.init(
                namespace: .solana,
                networkIDs: ["eip155:11155111"],
                methods: [.sendTransaction], events: []
            )],
            connector: .walletConnect,
            direction: .locusVaultToDapp
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .malformed) }
        XCTAssertThrowsError(try WalletConnectionNamespaceValidator.validate(
            [.init(
                namespace: .sui,
                networkIDs: ["sui:testnet"],
                methods: [.signInWithSolana], events: []
            )],
            connector: .walletConnect,
            direction: .locusVaultToDapp
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .methodNotApproved) }
    }

    func testLifecycleCannotReconnectAfterRevocation() throws {
        let connection = makeConnection()
        let revoked = try XCTUnwrap(connection.transitioning(
            to: .revoked, at: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(revoked.revokedAt, now.addingTimeInterval(1))
        XCTAssertNil(revoked.transitioning(
            to: .connected, at: now.addingTimeInterval(2)
        ))
    }

    func testSemanticRouterRejectsDuplicateAndExternalOwnershipSubstitution() throws {
        let connection = makeConnection()
        let binding = makeBinding(connection: connection)
        let action = WalletSemanticAction.nativeTransfer(
            recipient: "0x2222222222222222222222222222222222222222",
            amountBaseUnits: "1"
        )
        let request = WalletRoutedRequest(
            binding: binding,
            payload: .transaction(action: action, maximumFeeBaseUnits: "10")
        )
        let externalAccount = WalletAccount(
            id: "account-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "MetaMask", networkIDs: ["eip155:11155111"],
            ownership: .external(connectorID: .metamask)
        )
        let router = WalletDappRequestRouter()

        try router.begin(request, connection: connection, account: externalAccount, now: now)
        XCTAssertThrowsError(try router.begin(
            request, connection: connection, account: externalAccount, now: now
        )) { XCTAssertEqual($0 as? WalletDappRequestRouterError, .duplicateRequest) }

        let locusAccount = WalletAccount(
            id: externalAccount.id, chain: externalAccount.chain,
            address: externalAccount.address, label: "Locus Vault",
            networkIDs: externalAccount.networkIDs
        )
        let secondBinding = WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000002",
            connectionID: binding.connectionID, direction: binding.direction,
            connector: binding.connector, origin: binding.origin, peerID: binding.peerID,
            accountID: binding.accountID, networkID: binding.networkID,
            method: binding.method, issuedAt: binding.issuedAt,
            expiresAt: binding.expiresAt
        )
        XCTAssertThrowsError(try router.begin(
            WalletRoutedRequest(binding: secondBinding, payload: request.payload),
            connection: connection, account: locusAccount, now: now
        )) { XCTAssertEqual(
            $0 as? WalletDappRequestRouterError, .accountOwnershipMismatch
        ) }
    }

    func testSemanticRouterCancellationInvalidatesPendingCallback() throws {
        let connection = makeConnection()
        let binding = makeBinding(connection: connection)
        let account = WalletAccount(
            id: "account-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "MetaMask", networkIDs: ["eip155:11155111"],
            ownership: .external(connectorID: .metamask)
        )
        let router = WalletDappRequestRouter()
        try router.begin(
            WalletRoutedRequest(
                binding: binding,
                payload: .transaction(
                    action: .nativeTransfer(
                        recipient: "0x2222222222222222222222222222222222222222",
                        amountBaseUnits: "1"
                    ),
                    maximumFeeBaseUnits: "10"
                )
            ),
            connection: connection,
            account: account,
            now: now
        )

        router.cancel(requestID: binding.requestID, reason: .walletLocked)

        XCTAssertThrowsError(try router.complete(
            requestID: binding.requestID, callbackBinding: binding, now: now
        )) { XCTAssertEqual(
            $0 as? WalletDappRequestRouterError, .canceled(.walletLocked)
        ) }
    }

    func testSemanticRouterConsumesRequestAfterSubstitutedCallback() throws {
        let connection = makeConnection()
        let binding = makeBinding(connection: connection)
        let account = WalletAccount(
            id: "account-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "MetaMask", networkIDs: ["eip155:11155111"],
            ownership: .external(connectorID: .metamask)
        )
        let request = WalletRoutedRequest(
            binding: binding,
            payload: .transaction(
                action: .nativeTransfer(
                    recipient: "0x2222222222222222222222222222222222222222",
                    amountBaseUnits: "1"
                ),
                maximumFeeBaseUnits: "10"
            )
        )
        let router = WalletDappRequestRouter()
        try router.begin(request, connection: connection, account: account, now: now)
        let substituted = WalletConnectionRequestBinding(
            requestID: binding.requestID, connectionID: binding.connectionID,
            direction: binding.direction, connector: binding.connector,
            origin: binding.origin, peerID: binding.peerID,
            accountID: binding.accountID, networkID: "eip155:1",
            method: binding.method, issuedAt: binding.issuedAt,
            expiresAt: binding.expiresAt
        )

        XCTAssertThrowsError(try router.complete(
            requestID: binding.requestID, callbackBinding: substituted, now: now
        )) { XCTAssertEqual($0 as? WalletConnectionProtocolError, .bindingMismatch) }
        XCTAssertThrowsError(try router.begin(
            request, connection: connection, account: account, now: now
        )) { XCTAssertEqual($0 as? WalletDappRequestRouterError, .duplicateRequest) }
    }

    func testStructuredSIWEReconstructsCanonicalMessageAndRejectsDomainMismatch() throws {
        let account = WalletAccount(
            id: "account-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "Locus Vault", networkIDs: ["eip155:11155111"]
        )
        let request = WalletStructuredAuthorizationRequest(
            format: .siwe,
            domain: "app.example",
            origin: "https://app.example",
            networkID: "eip155:11155111",
            accountID: account.id,
            address: account.address,
            statement: "Sign in to Locus test",
            uri: "https://app.example/login",
            nonce: "aB123456",
            issuedAt: now.addingTimeInterval(-30),
            expirationTime: now.addingTimeInterval(300),
            notBefore: nil,
            requestID: "login-1",
            resources: ["https://app.example/terms"]
        )

        let message = try WalletStructuredAuthorization.canonicalMessage(
            request, account: account, now: now
        )
        XCTAssertTrue(message.hasPrefix(
            "app.example wants you to sign in with your Ethereum account:\n\(account.address)"
        ))
        XCTAssertTrue(message.contains("Chain ID: 11155111"))
        XCTAssertTrue(message.contains("Nonce: aB123456"))
        XCTAssertEqual(try WalletStructuredAuthorization.parseCanonicalMessage(
            message, format: .siwe, origin: request.origin,
            networkID: request.networkID, account: account, now: now
        ), request)
        XCTAssertThrowsError(try WalletStructuredAuthorization.parseCanonicalMessage(
            message + "\nInjected: arbitrary message", format: .siwe,
            origin: request.origin, networkID: request.networkID,
            account: account, now: now
        ))

        let mismatched = WalletStructuredAuthorizationRequest(
            format: request.format,
            domain: "attacker.example",
            origin: request.origin,
            networkID: request.networkID,
            accountID: request.accountID,
            address: request.address,
            statement: request.statement,
            uri: request.uri,
            nonce: request.nonce,
            issuedAt: request.issuedAt,
            expirationTime: request.expirationTime,
            notBefore: request.notBefore,
            requestID: request.requestID,
            resources: request.resources
        )
        XCTAssertThrowsError(try WalletStructuredAuthorization.validate(
            mismatched, account: account, now: now
        )) { XCTAssertEqual(
            $0 as? WalletStructuredAuthorizationError, .domainMismatch
        ) }
    }

    func testStructuredSIWSCanonicalRoundTrip() throws {
        let account = WalletAccount(
            id: "solana-1", chain: .solana,
            address: "11111111111111111111111111111111",
            label: "Locus Vault", networkIDs: ["solana:devnet"]
        )
        let request = WalletStructuredAuthorizationRequest(
            format: .siws, domain: "app.example",
            origin: "https://app.example", networkID: "solana:devnet",
            accountID: account.id, address: account.address,
            statement: "Sign in to the test application",
            uri: "https://app.example/session", nonce: "Solana123",
            issuedAt: now.addingTimeInterval(-30),
            expirationTime: now.addingTimeInterval(300),
            notBefore: now.addingTimeInterval(-10), requestID: "siws-1",
            resources: ["urn:locus:wallet:test"]
        )

        let message = try WalletStructuredAuthorization.canonicalMessage(
            request, account: account, now: now
        )

        XCTAssertTrue(message.contains("Chain ID: devnet"))
        XCTAssertEqual(try WalletStructuredAuthorization.parseCanonicalMessage(
            message, format: .siws, origin: request.origin,
            networkID: request.networkID, account: account, now: now
        ), request)
    }

    func testLaunchManifestRequiresExactConnectorDirectionAndMethod() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = WalletCapabilityManifest(
            schemaVersion: 3,
            revision: 9,
            releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "a", count: 64),
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600),
            networkGrants: [.init(
                networkID: "eip155:11155111",
                capabilities: [.externalWallet],
                connectors: [.init(
                    connector: .metamask,
                    directions: [.externalAccountToLocus],
                    methods: [.listAccounts, .sendTransaction]
                )]
            )],
            approvedRegions: ["CA"],
            completedApprovals: WalletLaunchGate.requiredCanaryApprovals
        )
        let signed = try signedCapability(manifest, key: privateKey)
        let gate = try WalletLaunchGate(
            signedManifest: signed,
            publicKey: privateKey.publicKey,
            now: now
        )

        XCTAssertNoThrow(try gate.authorizeConnection(
            networkID: "eip155:11155111",
            connector: .metamask,
            direction: .externalAccountToLocus,
            method: .sendTransaction,
            regionCode: "CA"
        ))
        XCTAssertThrowsError(try gate.authorizeConnection(
            networkID: "eip155:11155111",
            connector: .metamask,
            direction: .externalAccountToLocus,
            method: .signInWithEthereum,
            regionCode: "CA"
        )) { XCTAssertEqual($0 as? WalletLaunchGateError, .connectorNotReviewed) }
        XCTAssertThrowsError(try gate.authorizeConnection(
            networkID: "eip155:11155111",
            connector: .phantom,
            direction: .externalAccountToLocus,
            method: .sendTransaction,
            regionCode: "CA"
        )) { XCTAssertEqual($0 as? WalletLaunchGateError, .connectorNotReviewed) }
    }

    func testSignedManifestsCannotEnablePhantomForEthereumOrSIWE() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let capability = WalletCapabilityManifest(
            schemaVersion: 3,
            revision: 10,
            releaseStage: .invitedCanary,
            evidenceIndexSHA256: String(repeating: "a", count: 64),
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600),
            networkGrants: [.init(
                networkID: WalletGateway.sepoliaNetworkID,
                capabilities: [.externalWallet],
                connectors: [.init(
                    connector: .phantom,
                    directions: [.externalAccountToLocus],
                    methods: [.listAccounts, .sendTransaction]
                )]
            )],
            approvedRegions: ["CA"],
            completedApprovals: WalletLaunchGate.requiredCanaryApprovals
        )
        XCTAssertThrowsError(try WalletLaunchGate(
            signedManifest: signedCapability(capability, key: privateKey),
            publicKey: privateKey.publicKey, now: now
        )) { XCTAssertEqual($0 as? WalletLaunchGateError, .invalidManifest) }

        let review = WalletReviewManifest(
            schemaVersion: 2, revision: 10,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600),
            assets: [], evmContracts: [], explorerTemplates: [:],
            adapterIDs: [],
            connectors: [.init(
                connector: .phantom, version: "2.0.2",
                artifactSHA256: String(repeating: "b", count: 64),
                directions: [.externalAccountToLocus],
                methods: [.listAccounts, .sendTransaction, .signInWithEthereum]
            )],
            signInAdapters: [], programIdentities: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try privateKey.signature(for: encoder.encode(review))
        XCTAssertThrowsError(try WalletReviewRegistry(
            signedManifest: .init(
                manifest: review,
                signatureBase64: signature.base64EncodedString()
            ),
            publicKey: privateKey.publicKey, now: now
        )) { XCTAssertEqual($0 as? WalletReviewManifestError, .malformed) }
    }

    func testReviewManifestPinsConnectorSignInAndProgramIdentities() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifest = WalletReviewManifest(
            schemaVersion: 2,
            revision: 3,
            issuedAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(600),
            assets: [],
            evmContracts: [],
            explorerTemplates: [:],
            adapterIDs: [],
            connectors: [.init(
                connector: .metamask,
                version: "1.2.3",
                artifactSHA256: String(repeating: "a", count: 64),
                directions: [.externalAccountToLocus],
                methods: [.listAccounts, .sendTransaction, .signInWithEthereum]
            )],
            signInAdapters: [.init(
                format: .siwe,
                version: "1.0.0",
                implementationSHA256: String(repeating: "b", count: 64),
                networkIDs: ["eip155:11155111"]
            )],
            programIdentities: [.init(
                networkID: "eip155:11155111",
                kind: .evmRuntime,
                identifier: "uniswap-universal-router-v2",
                codeSHA256: String(repeating: "c", count: 64)
            )]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let signature = try privateKey.signature(for: encoder.encode(manifest))
        let registry = try WalletReviewRegistry(
            signedManifest: .init(
                manifest: manifest,
                signatureBase64: signature.base64EncodedString()
            ),
            publicKey: privateKey.publicKey,
            now: now
        )

        XCTAssertTrue(registry.containsSignInAdapter(
            format: .siwe, networkID: "eip155:11155111"
        ))
        XCTAssertFalse(registry.containsSignInAdapter(
            format: .siws, networkID: "solana:devnet"
        ))
    }

    func testExternalReconciliationRejectsChangedSemanticDigestBeforeProviderUse() async throws {
        let account = WalletAccount(
            id: "external-1", chain: .evm,
            address: "0x1111111111111111111111111111111111111111",
            label: "MetaMask", networkIDs: [WalletGateway.sepoliaNetworkID],
            ownership: .external(connectorID: .metamask)
        )
        let action = WalletSemanticAction.nativeTransfer(
            recipient: "0x2222222222222222222222222222222222222222",
            amountBaseUnits: "1"
        )
        do {
            _ = try await WalletSubmittedTransactionReconciler.reconcile(
                transactionID: "0x" + String(repeating: "a", count: 64),
                networkID: WalletGateway.sepoliaNetworkID,
                account: account, expectedAction: action,
                expectedSemanticDigest: "sha256:" + String(repeating: "0", count: 64)
            )
            XCTFail("A changed public semantic action must fail before provider lookup.")
        } catch let error as WalletConnectionProtocolError {
            XCTAssertEqual(error, .bindingMismatch)
        }
    }

    private func makeConnection() -> WalletConnectionRecord {
        WalletConnectionRecord(
            id: "connection-1", direction: .externalAccountToLocus,
            connector: .metamask, peerName: "MetaMask", peerURL: nil,
            networkIDs: ["eip155:11155111"],
            approvedMethods: [.listAccounts, .sendTransaction],
            accountIDs: ["account-1"], state: .connected,
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(60)
        )
    }

    private func makeBinding(
        connection: WalletConnectionRecord
    ) -> WalletConnectionRequestBinding {
        WalletConnectionRequestBinding(
            requestID: "00000000-0000-0000-0000-000000000001",
            connectionID: connection.id, direction: connection.direction,
            connector: connection.connector, origin: nil,
            peerID: nil, accountID: "account-1", networkID: "eip155:11155111",
            method: .sendTransaction, issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(30)
        )
    }

    private func signedCapability(
        _ manifest: WalletCapabilityManifest,
        key: Curve25519.Signing.PrivateKey
    ) throws -> WalletSignedCapabilityManifest {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return .init(
            manifest: manifest,
            signatureBase64: try key.signature(
                for: encoder.encode(manifest)
            ).base64EncodedString()
        )
    }
}
