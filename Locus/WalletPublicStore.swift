import Foundation
import SQLite3

private let walletSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct WalletContact: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let networkID: String
    let chain: WalletChain
    let name: String
    let rawAddress: String
    let resolvedName: String?
    let resolutionProof: String?
    let createdAt: Date
    let updatedAt: Date
}
enum WalletPublicStoreError: LocalizedError {
    case open(String)
    case statement(String)
    case bind(String)
    case step(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "The wallet database could not be opened: \(message)"
        case .statement(let message): "The wallet database statement failed: \(message)"
        case .bind(let message): "The wallet database value could not be bound: \(message)"
        case .step(let message): "The wallet database operation failed: \(message)"
        case .decode(let message): "The wallet database record is malformed: \(message)"
        }
    }
}

/// Versioned public wallet metadata. This store is deliberately incapable of
/// representing entropy, phrases, private keys, signer sessions, signed bytes,
/// or policy secrets. The signer and recovery services never open this file.
final class WalletPublicStore: @unchecked Sendable {
    static let schemaVersion = 2

    private let lock = NSLock()
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            throw WalletPublicStoreError.open("Application Support is unavailable")
        }
        let directory = base
            .appendingPathComponent("Locus", isDirectory: true)
            .appendingPathComponent("Wallet", isDirectory: true)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("wallet-public-v1.sqlite3")
    }

    convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    init(path: String) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw WalletPublicStoreError.open(message)
        }
        database = handle
        do {
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA busy_timeout = 5000")
            if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try migrate()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit {
        lock.lock()
        if let database { sqlite3_close(database) }
        database = nil
        lock.unlock()
    }

    func loadActivities(limit: Int = 500) throws -> [WalletActivityRecord] {
        try locked {
            var records: [WalletActivityRecord] = []
            let statement = try prepare(
                "SELECT payload FROM activity ORDER BY submitted_at DESC LIMIT ?"
            )
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 5_000)))) == SQLITE_OK else {
                throw bindError()
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                let data = try blob(statement, column: 0)
                do { records.append(try decoder.decode(WalletActivityRecord.self, from: data)) }
                catch { throw WalletPublicStoreError.decode(error.localizedDescription) }
            }
            guard sqlite3_errcode(database) == SQLITE_OK
                    || sqlite3_errcode(database) == SQLITE_DONE else { throw stepError() }
            return records
        }
    }

    func upsertActivity(_ record: WalletActivityRecord) throws {
        let payload = try encoder.encode(record)
        try locked {
            let statement = try prepare(
                """
                INSERT INTO activity(
                    id, intent_id, transaction_id, network_id, account_id,
                    state, submitted_at, payload
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    submitted_at = excluded.submitted_at,
                    payload = excluded.payload
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(record.id, at: 1, in: statement)
            try bind(record.intentID, at: 2, in: statement)
            try bind(record.transactionHash, at: 3, in: statement)
            try bind(record.networkID, at: 4, in: statement)
            try bind(record.accountID, at: 5, in: statement)
            try bind(record.state.rawValue, at: 6, in: statement)
            guard sqlite3_bind_double(statement, 7, record.submittedAt.timeIntervalSince1970) == SQLITE_OK,
                  payload.withUnsafeBytes({ bytes in
                      sqlite3_bind_blob(
                          statement, 8, bytes.baseAddress, Int32(bytes.count), walletSQLiteTransient
                      )
                  }) == SQLITE_OK else { throw bindError() }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
        }
    }

    func deleteActivity(id: String) throws {
        try locked {
            let statement = try prepare("DELETE FROM activity WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
        }
    }

    func migrateLegacyActivities(_ records: [WalletActivityRecord]) throws {
        guard !records.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for record in records.prefix(5_000) { try upsertActivity(record) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func loadContacts() throws -> [WalletContact] {
        try loadPayloads(
            sql: "SELECT payload FROM contacts ORDER BY name COLLATE NOCASE, updated_at DESC",
            as: WalletContact.self
        )
    }

    func upsertContact(_ contact: WalletContact) throws {
        try upsertPayload(
            table: "contacts", id: contact.id, networkID: contact.networkID,
            sortText: contact.name, timestamp: contact.updatedAt, value: contact
        )
    }

    func deleteContact(id: String) throws { try delete(table: "contacts", id: id) }

    func loadAssets() throws -> [WalletAsset] {
        try loadPayloads(
            sql: "SELECT payload FROM assets ORDER BY trust, symbol COLLATE NOCASE",
            as: WalletAsset.self
        )
    }

    func upsertAsset(_ asset: WalletAsset) throws {
        try upsertPayload(
            table: "assets", id: asset.id, networkID: asset.networkID,
            sortText: asset.symbol, timestamp: Date(), value: asset,
            extraColumn: "trust", extraValue: asset.trust.rawValue
        )
    }

    func loadConnections() throws -> [WalletConnectionRecord] {
        try loadPayloads(
            sql: "SELECT payload FROM connections ORDER BY updated_at DESC",
            as: WalletConnectionRecord.self
        )
    }

    func upsertConnection(_ connection: WalletConnectionRecord) throws {
        let payload = try encoder.encode(connection)
        try locked {
            let statement = try prepare(
                """
                INSERT INTO connections(
                    id, network_id, peer_name, updated_at, payload,
                    direction, connector_id, state, expires_at, revoked_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    network_id = excluded.network_id,
                    peer_name = excluded.peer_name,
                    updated_at = excluded.updated_at,
                    payload = excluded.payload,
                    direction = excluded.direction,
                    connector_id = excluded.connector_id,
                    state = excluded.state,
                    expires_at = excluded.expires_at,
                    revoked_at = excluded.revoked_at
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(connection.id, at: 1, in: statement)
            try bind(
                connection.networkIDs.sorted().joined(separator: ","),
                at: 2,
                in: statement
            )
            try bind(connection.peerName, at: 3, in: statement)
            guard sqlite3_bind_double(
                statement, 4, connection.updatedAt.timeIntervalSince1970
            ) == SQLITE_OK,
            payload.withUnsafeBytes({ bytes in
                sqlite3_bind_blob(
                    statement, 5, bytes.baseAddress, Int32(bytes.count), walletSQLiteTransient
                )
            }) == SQLITE_OK else { throw bindError() }
            try bind(connection.direction.rawValue, at: 6, in: statement)
            try bind(connection.connector.rawValue, at: 7, in: statement)
            try bind(connection.state.rawValue, at: 8, in: statement)
            guard sqlite3_bind_double(
                statement, 9, connection.expiresAt.timeIntervalSince1970
            ) == SQLITE_OK else { throw bindError() }
            if let revokedAt = connection.revokedAt {
                guard sqlite3_bind_double(
                    statement, 10, revokedAt.timeIntervalSince1970
                ) == SQLITE_OK else { throw bindError() }
            } else if sqlite3_bind_null(statement, 10) != SQLITE_OK {
                throw bindError()
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
        }
    }

    func deleteConnection(id: String) throws { try delete(table: "connections", id: id) }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS wallet_schema (
                version INTEGER NOT NULL
            )
            """
        )
        let current = try scalarInt("SELECT COALESCE(MAX(version), 0) FROM wallet_schema")
        guard current <= Self.schemaVersion else {
            throw WalletPublicStoreError.open("database schema \(current) is newer than this app")
        }
        if current < 1 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute(
                    """
                    CREATE TABLE activity (
                        id TEXT PRIMARY KEY,
                        intent_id TEXT NOT NULL,
                        transaction_id TEXT NOT NULL,
                        network_id TEXT NOT NULL,
                        account_id TEXT NOT NULL,
                        state TEXT NOT NULL,
                        submitted_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """
                )
                try execute(
                    "CREATE INDEX activity_account_time ON activity(account_id, submitted_at DESC)"
                )
                try execute(
                    """
                    CREATE TABLE contacts (
                        id TEXT PRIMARY KEY,
                        network_id TEXT NOT NULL,
                        name TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """
                )
                try execute(
                    """
                    CREATE TABLE assets (
                        id TEXT PRIMARY KEY,
                        network_id TEXT NOT NULL,
                        symbol TEXT NOT NULL,
                        trust TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """
                )
                try execute(
                    """
                    CREATE TABLE connections (
                        id TEXT PRIMARY KEY,
                        network_id TEXT NOT NULL,
                        peer_name TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        payload BLOB NOT NULL
                    )
                    """
                )
                try execute("DELETE FROM wallet_schema")
                try execute("INSERT INTO wallet_schema(version) VALUES(1)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
        if current < 2 {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("ALTER TABLE connections ADD COLUMN direction TEXT")
                try execute("ALTER TABLE connections ADD COLUMN connector_id TEXT")
                try execute("ALTER TABLE connections ADD COLUMN state TEXT")
                try execute("ALTER TABLE connections ADD COLUMN expires_at REAL")
                try execute("ALTER TABLE connections ADD COLUMN revoked_at REAL")
                try execute(
                    "CREATE INDEX connections_lifecycle ON connections(state, expires_at)"
                )
                try execute("DELETE FROM wallet_schema")
                try execute("INSERT INTO wallet_schema(version) VALUES(2)")
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func upsertPayload<T: Encodable>(
        table: String,
        id: String,
        networkID: String,
        sortText: String,
        timestamp: Date,
        value: T,
        extraColumn: String? = nil,
        extraValue: String? = nil
    ) throws {
        let allowedTables = Set(["contacts", "assets", "connections"])
        guard allowedTables.contains(table) else {
            throw WalletPublicStoreError.statement("invalid table")
        }
        let sortColumn = table == "contacts" ? "name" : table == "assets" ? "symbol" : "peer_name"
        let payload = try encoder.encode(value)
        let extraInsert = extraColumn.map { ", \($0)" } ?? ""
        let extraPlaceholder = extraColumn == nil ? "" : ", ?"
        let extraUpdate = extraColumn.map { ", \($0) = excluded.\($0)" } ?? ""
        let sql = """
            INSERT INTO \(table)(id, network_id, \(sortColumn), updated_at, payload\(extraInsert))
            VALUES(?, ?, ?, ?, ?\(extraPlaceholder))
            ON CONFLICT(id) DO UPDATE SET network_id = excluded.network_id,
                \(sortColumn) = excluded.\(sortColumn), updated_at = excluded.updated_at,
                payload = excluded.payload\(extraUpdate)
            """
        try locked {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, in: statement)
            try bind(networkID, at: 2, in: statement)
            try bind(sortText, at: 3, in: statement)
            guard sqlite3_bind_double(statement, 4, timestamp.timeIntervalSince1970) == SQLITE_OK,
                  payload.withUnsafeBytes({ bytes in
                      sqlite3_bind_blob(
                          statement, 5, bytes.baseAddress, Int32(bytes.count), walletSQLiteTransient
                      )
                  }) == SQLITE_OK else { throw bindError() }
            if let extraValue { try bind(extraValue, at: 6, in: statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
        }
    }

    private func loadPayloads<T: Decodable>(sql: String, as type: T.Type) throws -> [T] {
        try locked {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var values: [T] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                do { values.append(try decoder.decode(T.self, from: blob(statement, column: 0))) }
                catch { throw WalletPublicStoreError.decode(error.localizedDescription) }
            }
            guard sqlite3_errcode(database) == SQLITE_OK
                    || sqlite3_errcode(database) == SQLITE_DONE else { throw stepError() }
            return values
        }
    }

    private func delete(table: String, id: String) throws {
        guard ["contacts", "connections"].contains(table) else {
            throw WalletPublicStoreError.statement("invalid table")
        }
        try locked {
            let statement = try prepare("DELETE FROM \(table) WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(id, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        try locked {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func execute(_ sql: String) throws {
        try locked {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? databaseMessage()
                sqlite3_free(error)
                throw WalletPublicStoreError.statement(message)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw WalletPublicStoreError.statement(databaseMessage()) }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, walletSQLiteTransient) == SQLITE_OK else {
            throw bindError()
        }
    }

    private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count >= 0 else { throw WalletPublicStoreError.decode("negative blob length") }
        guard count > 0 else { return Data() }
        guard let pointer = sqlite3_column_blob(statement, column) else {
            throw WalletPublicStoreError.decode("missing blob")
        }
        return Data(bytes: pointer, count: count)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func databaseMessage() -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "database is closed"
    }

    private func bindError() -> WalletPublicStoreError { .bind(databaseMessage()) }
    private func stepError() -> WalletPublicStoreError { .step(databaseMessage()) }
}
