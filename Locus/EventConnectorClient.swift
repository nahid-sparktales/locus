import AuthenticationServices
import CryptoKit
import Foundation
import AppKit

enum EventConnectorClientError: LocalizedError {
    case unavailable(String)
    case invalidResponse(String)
    case provider(Int, String)
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidResponse(let message): message
        case .provider(let status, let message): "Connector request failed (\(status)): \(message)"
        case .payloadTooLarge: "The connector payload is larger than Locus allows."
        }
    }
}

struct ConnectorPollResult {
    let events: [InboundEvent]
    let cursor: [String: JSONValue]
}

@MainActor
final class GmailOAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(clientID: String) async throws -> [String: String] {
        let cleanClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanClientID.isEmpty else {
            throw EventConnectorClientError.unavailable(
                "This build has no Google OAuth client ID. Set LOCUS_GOOGLE_OAUTH_CLIENT_ID before building."
            )
        }
        let verifier = Self.base64URL(Data((0..<48).map { _ in UInt8.random(in: 0...255) }))
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: cleanClientID),
            URLQueryItem(name: "redirect_uri", value: "locus://oauth/google"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/gmail.modify"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let authorizationURL = components.url else {
            throw EventConnectorClientError.invalidResponse("Could not create the Google sign-in URL.")
        }
        let callbackURL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "locus"
            ) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else {
                    continuation.resume(throwing: EventConnectorClientError.invalidResponse(
                        "Google sign-in returned no authorization code."
                    ))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                continuation.resume(throwing: EventConnectorClientError.unavailable(
                    "Google sign-in could not be opened."
                ))
                return
            }
        }
        self.session = nil
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw EventConnectorClientError.invalidResponse("Google sign-in returned no authorization code.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": cleanClientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": "locus://oauth/google",
        ].formEncoded
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String
        else {
            throw EventConnectorClientError.invalidResponse("Google token exchange failed.")
        }
        let expires = Date().addingTimeInterval(object["expires_in"] as? Double ?? 3_600)
        return [
            "access_token": access,
            "refresh_token": object["refresh_token"] as? String ?? "",
            "expires_at": String(expires.timeIntervalSince1970),
            "client_id": cleanClientID,
        ]
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

actor EventConnectorClient {
    private let credentials: ConnectorCredentialStore
    private let session: URLSession

    init(
        credentials: ConnectorCredentialStore = .shared,
        session: URLSession = .shared
    ) {
        self.credentials = credentials
        self.session = session
    }

    func poll(_ connection: ConnectorConnection) async throws -> ConnectorPollResult {
        switch connection.kind {
        case .gmail: try await pollGmail(connection)
        case .telegram: try await pollTelegram(connection)
        case .webhook: ConnectorPollResult(events: [], cursor: connection.cursor)
        }
    }

    func performAction(
        tool: String,
        arguments: [String: Any],
        workspacePath: String
    ) async throws -> [String: Any] {
        guard let connectionID = arguments["connection_id"] as? String,
              !connectionID.isEmpty else {
            throw EventConnectorClientError.invalidResponse("A connector connection is required.")
        }
        if tool.hasPrefix("gmail_") {
            return try await performGmailAction(
                tool, arguments: arguments, connectionID: connectionID,
                workspacePath: workspacePath
            )
        }
        if tool.hasPrefix("telegram_") {
            return try await performTelegramAction(
                tool, arguments: arguments, connectionID: connectionID,
                workspacePath: workspacePath
            )
        }
        throw EventConnectorClientError.invalidResponse("Unknown connector action.")
    }

    // MARK: Gmail ingestion

    private func pollGmail(_ connection: ConnectorConnection) async throws -> ConnectorPollResult {
        let priorHistoryID = connection.cursor["history_id"]?.string ?? ""
        if priorHistoryID.isEmpty {
            let profile = try await gmailJSON(connection.id, path: "profile")
            guard let historyID = Self.stringValue(profile["historyId"]) else {
                throw EventConnectorClientError.invalidResponse("Gmail profile has no history cursor.")
            }
            return ConnectorPollResult(events: [], cursor: [
                "history_id": .string(historyID),
                "last_successful_at": .number(Date().timeIntervalSince1970),
                "recent_message_ids": .array([]),
            ])
        }

        var pageToken = ""
        var newHistoryID = priorHistoryID
        var messageIDs: [String] = []
        do {
            repeat {
                var query = [
                    URLQueryItem(name: "startHistoryId", value: priorHistoryID),
                    URLQueryItem(name: "historyTypes", value: "messageAdded"),
                    URLQueryItem(name: "maxResults", value: "100"),
                ]
                if !pageToken.isEmpty { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
                let page = try await gmailJSON(connection.id, path: "history", query: query)
                newHistoryID = Self.stringValue(page["historyId"]) ?? newHistoryID
                for history in page["history"] as? [[String: Any]] ?? [] {
                    for added in history["messagesAdded"] as? [[String: Any]] ?? [] {
                        if let message = added["message"] as? [String: Any],
                           let identifier = message["id"] as? String {
                            messageIDs.append(identifier)
                        }
                    }
                }
                pageToken = page["nextPageToken"] as? String ?? ""
            } while !pageToken.isEmpty
        } catch EventConnectorClientError.provider(let status, _) where status == 404 {
            return try await reconcileGmail(connection)
        }
        let recent = Set((connection.cursor["recent_message_ids"]?.arrayStrings ?? []))
        let unique = Self.uniqueIDs(messageIDs)
        let events = try await unique.filter { !recent.contains($0) }.asyncMap {
            try await self.gmailEvent(connection.id, messageID: $0)
        }
        let remembered = Self.uniqueIDs(Array(unique.reversed()) + Array(recent)).prefix(500)
        return ConnectorPollResult(events: events, cursor: [
            "history_id": .string(newHistoryID),
            "last_successful_at": .number(Date().timeIntervalSince1970),
            "recent_message_ids": .array(remembered.map(JSONValue.string)),
        ])
    }

    private func reconcileGmail(_ connection: ConnectorConnection) async throws -> ConnectorPollResult {
        let since = Int(connection.cursor["last_successful_at"]?.doubleValue ?? Date().addingTimeInterval(-300).timeIntervalSince1970)
        var pageToken = ""
        var ids: [String] = []
        repeat {
            var query = [
                URLQueryItem(name: "q", value: "after:\(max(since - 60, 1))"),
                URLQueryItem(name: "includeSpamTrash", value: "false"),
                URLQueryItem(name: "maxResults", value: "500"),
            ]
            if !pageToken.isEmpty {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let list = try await gmailJSON(connection.id, path: "messages", query: query)
            ids.append(contentsOf: (list["messages"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String })
            pageToken = list["nextPageToken"] as? String ?? ""
        } while !pageToken.isEmpty
        ids = Self.uniqueIDs(ids)
        let recent = Set(connection.cursor["recent_message_ids"]?.arrayStrings ?? [])
        let fresh = ids.filter { !recent.contains($0) }.reversed()
        let events = try await Array(fresh).asyncMap {
            try await self.gmailEvent(connection.id, messageID: $0)
        }
        let profile = try await gmailJSON(connection.id, path: "profile")
        guard let historyID = Self.stringValue(profile["historyId"]) else {
            throw EventConnectorClientError.invalidResponse("Gmail could not establish a fresh history cursor.")
        }
        return ConnectorPollResult(events: events, cursor: [
            "history_id": .string(historyID),
            "last_successful_at": .number(Date().timeIntervalSince1970),
            "recent_message_ids": .array(
                Array(Self.uniqueIDs(ids + Array(recent)).prefix(500)).map(JSONValue.string)
            ),
        ])
    }

    private func gmailEvent(_ connectionID: String, messageID: String) async throws -> InboundEvent {
        let message = try await gmailJSON(connectionID, path: "messages/\(messageID)", query: [
            URLQueryItem(name: "format", value: "full")
        ])
        let payload = message["payload"] as? [String: Any] ?? [:]
        let headers = Self.gmailHeaders(payload)
        let parts = Self.gmailParts(payload)
        let sender = Self.mailbox(headers["from"] ?? "")
        let timestamp = (Double(Self.stringValue(message["internalDate"]) ?? "") ?? Date().timeIntervalSince1970 * 1_000) / 1_000
        return InboundEvent(
            source: .gmail,
            sourceEventID: messageID,
            eventType: "message",
            occurredAt: timestamp,
            actor: ["email": .string(sender), "name": .string(headers["from"] ?? sender)],
            subject: headers["subject"] ?? "",
            text: Self.gmailText(payload, fallback: message["snippet"] as? String ?? ""),
            recipients: Self.mailboxes([headers["to"], headers["cc"]].compactMap { $0 }.joined(separator: ",")),
            labels: message["labelIds"] as? [String] ?? [],
            attachments: parts.compactMap { part in
                guard let body = part["body"] as? [String: Any],
                      let attachmentID = body["attachmentId"] as? String else { return nil }
                return [
                    "id": .string(attachmentID),
                    "message_id": .string(messageID),
                    "filename": .string(part["filename"] as? String ?? "attachment"),
                    "mime_type": .string(part["mimeType"] as? String ?? "application/octet-stream"),
                    "size": .number(Double(body["size"] as? Int ?? 0)),
                ]
            },
            data: [
                "thread_id": .string(message["threadId"] as? String ?? ""),
                "message_id": .string(messageID),
                "rfc_message_id": .string(headers["message-id"] ?? ""),
            ]
        )
    }

    // MARK: Telegram ingestion

    private func pollTelegram(_ connection: ConnectorConnection) async throws -> ConnectorPollResult {
        let offset = connection.cursor["offset"]?.integerValue ?? 0
        let response = try await telegramJSON(connection.id, method: "getUpdates", body: [
            "offset": offset,
            "timeout": 25,
            "allowed_updates": ["message", "edited_message", "channel_post", "edited_channel_post"],
        ], timeout: 35)
        let updates = response["result"] as? [[String: Any]] ?? []
        var events: [InboundEvent] = []
        var nextOffset = offset
        for update in updates {
            guard let updateID = update["update_id"] as? Int else { continue }
            nextOffset = max(nextOffset, updateID + 1)
            let key = ["message", "edited_message", "channel_post", "edited_channel_post"]
                .first { update[$0] is [String: Any] }
            guard let key, let message = update[key] as? [String: Any] else { continue }
            let actor = message["from"] as? [String: Any] ?? message["sender_chat"] as? [String: Any] ?? [:]
            let chat = message["chat"] as? [String: Any] ?? [:]
            let eventType = Self.telegramMessageType(message)
            let attachments = Self.telegramAttachments(message)
            events.append(InboundEvent(
                source: .telegram,
                sourceEventID: String(updateID),
                eventType: eventType,
                occurredAt: Double(message["date"] as? Int ?? Int(Date().timeIntervalSince1970)),
                actor: [
                    "id": .string(Self.stringValue(actor["id"]) ?? ""),
                    "username": .string(actor["username"] as? String ?? ""),
                    "name": .string([actor["first_name"], actor["last_name"]]
                        .compactMap { $0 as? String }.joined(separator: " ")),
                ],
                subject: chat["title"] as? String ?? "Telegram message",
                text: message["text"] as? String ?? message["caption"] as? String ?? "",
                recipients: [], labels: [], attachments: attachments,
                data: [
                    "chat_id": .string(Self.stringValue(chat["id"]) ?? ""),
                    "message_id": .number(Double(message["message_id"] as? Int ?? 0)),
                    "update_kind": .string(key),
                ]
            ))
        }
        return ConnectorPollResult(events: events, cursor: ["offset": .number(Double(nextOffset))])
    }

    // MARK: Native connector tools

    private func performGmailAction(
        _ tool: String,
        arguments: [String: Any],
        connectionID: String,
        workspacePath: String
    ) async throws -> [String: Any] {
        switch tool {
        case "gmail_fetch_thread":
            let threadID = try Self.requiredString(arguments, "thread_id")
            let thread = try await gmailJSON(connectionID, path: "threads/\(threadID)", query: [
                URLQueryItem(name: "format", value: "full")
            ])
            let messages = thread["messages"] as? [[String: Any]] ?? []
            let summaries = messages.map { message -> [String: Any] in
                let payload = message["payload"] as? [String: Any] ?? [:]
                let headers = Self.gmailHeaders(payload)
                return [
                    "id": message["id"] as? String ?? "",
                    "from": headers["from"] ?? "",
                    "to": headers["to"] ?? "",
                    "subject": headers["subject"] ?? "",
                    "message_id": headers["message-id"] ?? "",
                    "text": Self.gmailText(payload, fallback: message["snippet"] as? String ?? ""),
                ]
            }
            return ["text": try Self.prettyJSON(["thread_id": threadID, "messages": summaries])]
        case "gmail_fetch_attachment":
            let messageID = try Self.requiredString(arguments, "message_id")
            let attachmentID = try Self.requiredString(arguments, "attachment_id")
            let filename = Self.safeFilename(try Self.requiredString(arguments, "filename"))
            let object = try await gmailJSON(
                connectionID, path: "messages/\(messageID)/attachments/\(attachmentID)"
            )
            guard let encoded = object["data"] as? String,
                  let data = Data(base64URLEncoded: encoded), data.count <= 25 * 1_024 * 1_024 else {
                throw EventConnectorClientError.payloadTooLarge
            }
            let url = try Self.destination(workspacePath: workspacePath, filename: filename)
            try data.write(to: url, options: .atomic)
            return ["text": "Downloaded \(filename) to \(url.path)", "path": url.path]
        case "gmail_change_labels":
            let targetID = try Self.requiredString(arguments, "target_id")
            let targetType = (arguments["target_type"] as? String) == "thread" ? "threads" : "messages"
            let result = try await gmailJSON(
                connectionID, path: "\(targetType)/\(targetID)/modify", method: "POST",
                body: [
                    "addLabelIds": arguments["add_label_ids"] as? [String] ?? [],
                    "removeLabelIds": arguments["remove_label_ids"] as? [String] ?? [],
                ]
            )
            return ["text": "Gmail labels updated.", "id": result["id"] as? String ?? targetID]
        case "gmail_create_draft", "gmail_send":
            let raw = try Self.gmailRawMessage(arguments)
            var body: [String: Any] = ["raw": Self.base64URL(Data(raw.utf8))]
            if let threadID = arguments["thread_id"] as? String, !threadID.isEmpty {
                body["threadId"] = threadID
            }
            let path = tool == "gmail_send" ? "messages/send" : "drafts"
            let envelope = tool == "gmail_send" ? body : ["message": body]
            let result = try await gmailJSON(
                connectionID, path: path, method: "POST", body: envelope
            )
            return [
                "text": tool == "gmail_send" ? "Gmail message sent." : "Gmail draft created.",
                "id": result["id"] as? String ?? "",
            ]
        default:
            throw EventConnectorClientError.invalidResponse("Unknown Gmail action.")
        }
    }

    private func performTelegramAction(
        _ tool: String,
        arguments: [String: Any],
        connectionID: String,
        workspacePath: String
    ) async throws -> [String: Any] {
        switch tool {
        case "telegram_send":
            var body: [String: Any] = [
                "chat_id": try Self.requiredString(arguments, "chat_id"),
                "text": try Self.requiredString(arguments, "text"),
            ]
            if let replyID = arguments["reply_to_message_id"] as? Int {
                body["reply_parameters"] = ["message_id": replyID]
            }
            let result = try await telegramJSON(connectionID, method: "sendMessage", body: body)
            let message = result["result"] as? [String: Any] ?? [:]
            return ["text": "Telegram message sent.", "message_id": message["message_id"] ?? 0]
        case "telegram_fetch_file":
            let fileID = try Self.requiredString(arguments, "file_id")
            let filename = Self.safeFilename(try Self.requiredString(arguments, "filename"))
            let info = try await telegramJSON(connectionID, method: "getFile", body: ["file_id": fileID])
            guard let result = info["result"] as? [String: Any],
                  let filePath = result["file_path"] as? String else {
                throw EventConnectorClientError.invalidResponse("Telegram returned no file path.")
            }
            let token = try await telegramToken(connectionID)
            let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)")!
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                throw EventConnectorClientError.unavailable("Telegram could not download the file.")
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw EventConnectorClientError.invalidResponse("Telegram file download failed.")
            }
            guard data.count <= 20 * 1_024 * 1_024 else { throw EventConnectorClientError.payloadTooLarge }
            let destination = try Self.destination(workspacePath: workspacePath, filename: filename)
            try data.write(to: destination, options: .atomic)
            return ["text": "Downloaded \(filename) to \(destination.path)", "path": destination.path]
        default:
            throw EventConnectorClientError.invalidResponse("Unknown Telegram action.")
        }
    }

    // MARK: Provider transport

    private func gmailJSON(
        _ connectionID: String,
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: [String: Any]? = nil,
        didRefresh: Bool = false
    ) async throws -> [String: Any] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(try await gmailAccessToken(connectionID))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EventConnectorClientError.unavailable("Gmail could not be reached.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw EventConnectorClientError.invalidResponse("Gmail returned no HTTP response.")
        }
        if http.statusCode == 401, !didRefresh {
            _ = try await refreshGmailToken(connectionID)
            return try await gmailJSON(
                connectionID, path: path, query: query, method: method,
                body: body, didRefresh: true
            )
        }
        guard 200..<300 ~= http.statusCode else {
            throw EventConnectorClientError.provider(
                http.statusCode,
                String(data: data.prefix(4_000), encoding: .utf8) ?? "Gmail error"
            )
        }
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventConnectorClientError.invalidResponse("Gmail returned malformed JSON.")
        }
        return object
    }

    private func telegramJSON(
        _ connectionID: String,
        method: String,
        body: [String: Any],
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        let token = try await telegramToken(connectionID)
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Telegram bot tokens are part of the provider URL. Never allow a
            // transport error containing that URL to cross into Python or a
            // transcript.
            throw EventConnectorClientError.unavailable("Telegram could not be reached.")
        }
        guard let http = response as? HTTPURLResponse,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventConnectorClientError.invalidResponse("Telegram returned malformed data.")
        }
        guard http.statusCode == 200, object["ok"] as? Bool == true else {
            throw EventConnectorClientError.provider(
                http.statusCode, object["description"] as? String ?? "Telegram error"
            )
        }
        return object
    }

    private func gmailAccessToken(_ connectionID: String) async throws -> String {
        guard let value = try credentials.load(for: connectionID),
              let access = value["access_token"], !access.isEmpty else {
            throw EventConnectorClientError.unavailable("Gmail needs to be connected again.")
        }
        let expires = Double(value["expires_at"] ?? "") ?? 0
        if expires > Date().addingTimeInterval(60).timeIntervalSince1970 { return access }
        return try await refreshGmailToken(connectionID)
    }

    private func refreshGmailToken(_ connectionID: String) async throws -> String {
        guard var value = try credentials.load(for: connectionID),
              let refresh = value["refresh_token"], !refresh.isEmpty,
              let clientID = value["client_id"], !clientID.isEmpty else {
            throw EventConnectorClientError.unavailable("Gmail needs to be connected again.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "client_id": clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ].formEncoded
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else {
            throw EventConnectorClientError.unavailable("Gmail token refresh failed; reconnect the account.")
        }
        value["access_token"] = access
        value["expires_at"] = String(Date().addingTimeInterval(object["expires_in"] as? Double ?? 3_600).timeIntervalSince1970)
        try credentials.save(value, for: connectionID)
        return access
    }

    private func telegramToken(_ connectionID: String) async throws -> String {
        guard let token = try credentials.load(for: connectionID)?["bot_token"], !token.isEmpty else {
            throw EventConnectorClientError.unavailable("The Telegram bot token is missing.")
        }
        return token
    }

    // MARK: Parsing and bounds

    private static func gmailHeaders(_ payload: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for header in payload["headers"] as? [[String: Any]] ?? [] {
            guard let name = header["name"] as? String,
                  let value = header["value"] as? String else { continue }
            result[name.lowercased()] = value
        }
        return result
    }

    private static func gmailParts(_ payload: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        func visit(_ part: [String: Any]) {
            result.append(part)
            for child in part["parts"] as? [[String: Any]] ?? [] { visit(child) }
        }
        visit(payload)
        return result
    }

    private static func gmailText(_ payload: [String: Any], fallback: String) -> String {
        for part in gmailParts(payload) where (part["mimeType"] as? String) == "text/plain" {
            if let body = part["body"] as? [String: Any],
               let encoded = body["data"] as? String,
               let data = Data(base64URLEncoded: encoded),
               let text = String(data: data, encoding: .utf8) {
                return String(text.prefix(120_000))
            }
        }
        return String(fallback.prefix(120_000))
    }

    private static func telegramMessageType(_ message: [String: Any]) -> String {
        for key in ["text", "photo", "document", "video", "audio", "voice", "sticker", "location", "contact"] {
            if message[key] != nil { return key }
        }
        return "message"
    }

    private static func telegramAttachments(_ message: [String: Any]) -> [[String: JSONValue]] {
        if let document = message["document"] as? [String: Any],
           let fileID = document["file_id"] as? String {
            return [[
                "id": .string(fileID),
                "filename": .string(document["file_name"] as? String ?? "telegram-file"),
                "mime_type": .string(document["mime_type"] as? String ?? "application/octet-stream"),
                "size": .number(Double(document["file_size"] as? Int ?? 0)),
            ]]
        }
        if let photos = message["photo"] as? [[String: Any]], let photo = photos.last,
           let fileID = photo["file_id"] as? String {
            return [[
                "id": .string(fileID), "filename": .string("telegram-photo.jpg"),
                "mime_type": .string("image/jpeg"),
                "size": .number(Double(photo["file_size"] as? Int ?? 0)),
            ]]
        }
        return []
    }

    private static func gmailRawMessage(_ arguments: [String: Any]) throws -> String {
        let to = (arguments["to"] as? [String] ?? []).joined(separator: ", ")
        guard !to.isEmpty else { throw EventConnectorClientError.invalidResponse("At least one recipient is required.") }
        let cc = (arguments["cc"] as? [String] ?? []).joined(separator: ", ")
        let subject = try requiredString(arguments, "subject")
        let body = try requiredString(arguments, "body")
        var lines = ["To: \(to)"]
        if !cc.isEmpty { lines.append("Cc: \(cc)") }
        lines += [
            "Subject: \(subject.replacingOccurrences(of: "\n", with: " "))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
        ]
        if let reply = arguments["in_reply_to"] as? String, !reply.isEmpty {
            lines += ["In-Reply-To: \(reply)", "References: \(reply)"]
        }
        lines += ["", body]
        return lines.joined(separator: "\r\n")
    }

    private static func mailbox(_ value: String) -> String {
        if let start = value.lastIndex(of: "<"), let end = value[start...].firstIndex(of: ">") {
            return String(value[value.index(after: start)..<end]).trimmingCharacters(in: .whitespaces)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func mailboxes(_ value: String) -> [String] {
        value.split(separator: ",").map { mailbox(String($0)) }.filter { !$0.isEmpty }
    }

    private static func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EventConnectorClientError.invalidResponse("\(key) is required.")
        }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func prettyJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func uniqueIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func safeFilename(_ value: String) -> String {
        let name = URL(fileURLWithPath: value).lastPathComponent
        return name.isEmpty ? "attachment" : String(name.prefix(180))
    }

    private static func destination(workspacePath: String, filename: String) throws -> URL {
        let root = URL(fileURLWithPath: workspacePath, isDirectory: true)
        let folder = root.appendingPathComponent("Locus Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(safeFilename(filename))
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
            throw EventConnectorClientError.invalidResponse("The attachment filename is unsafe.")
        }
        return url
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Dictionary where Key == String, Value == String {
    var formEncoded: Data? {
        map { key, value in
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            return "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .sorted()
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var encoded = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        self.init(base64Encoded: encoded)
    }
}

private extension JSONValue {
    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        if case .string(let value) = self { return Double(value) }
        return nil
    }

    var integerValue: Int? { doubleValue.map(Int.init) }

    var arrayStrings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.string)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
