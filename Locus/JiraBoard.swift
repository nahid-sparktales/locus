import Foundation

struct JiraIssueLink: Codable, Hashable {
    var serverID: String
    var cloudID: String
    var siteURL: String
    var key: String
    var remoteTitle: String
    var remoteDetails: String
    var remoteUpdated: String
    var status: String
    var statusCategory: String
    var identity: String { cloudID + ":" + key }
    var url: URL? {
        guard var components = URLComponents(string: siteURL), components.scheme == "https",
              components.host != nil, components.user == nil, components.password == nil else { return nil }
        components.path = "/browse/" + key; components.query = nil; components.fragment = nil
        return components.url
    }
}

struct JiraSite: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
}

struct JiraTransition: Identifiable { let id: String; let name: String }

enum JiraBoardError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

extension JSONValue {
    var jiraObject: [String: JSONValue] { if case .object(let value) = self { return value }; return [:] }
    var jiraArray: [JSONValue] { if case .array(let value) = self { return value }; return [] }
    /// Preserve paragraph boundaries when displaying Jira's rich-text documents.
    var jiraText: String {
        if case .string(let value) = self { return value }
        let object = jiraObject
        if let text = object["text"]?.string { return text }
        if object["type"]?.string == "hardBreak" { return "\n" }
        return (object["content"]?.jiraArray ?? []).map { node in
            let value = node.jiraText
            return ["paragraph", "heading", "listItem", "codeBlock"].contains(node.jiraObject["type"]?.string ?? "") ? value + "\n" : value
        }.joined()
    }
}

@MainActor
final class JiraBoardClient: ObservableObject {
    struct Response: Decodable { let data: JSONValue }
    let backend: BackendService
    let workspace: String
    init(backend: BackendService, workspace: String) { self.backend = backend; self.workspace = workspace }

    func call(_ operation: String, serverID: String, arguments: [String: Any] = [:]) async throws -> JSONValue {
        let response = try await backend.post("/api/integrations/jira", body: [
            "operation": operation, "server_id": serverID, "workspace": workspace, "arguments": arguments,
        ], as: Response.self)
        return response.data
    }

    func sites(serverID: String) async throws -> [JiraSite] {
        let result = try await call("sites", serverID: serverID)
        let values = result.jiraArray.isEmpty ? (result.jiraObject["resources"]?.jiraArray ?? []) : result.jiraArray
        let sites = values.compactMap { value -> JiraSite? in
            let item = value.jiraObject
            guard let id = item["id"]?.string ?? item["cloudId"]?.string,
                  let url = item["url"]?.string, URL(string: url)?.scheme == "https" else { return nil }
            return JiraSite(id: id, name: item["name"]?.string ?? url, url: url)
        }
        guard !sites.isEmpty else { throw JiraBoardError.message("No Jira sites are available for this account. Check your Atlassian access.") }
        return sites
    }

    static func issue(_ value: JSONValue, serverID: String, site: JiraSite) throws -> JiraIssueLink {
        let item = value.jiraObject
        let fields = item["fields"]?.jiraObject ?? [:]
        guard let key = item["key"]?.string, !key.isEmpty,
              let title = fields["summary"]?.string,
              let updated = fields["updated"]?.string else {
            throw JiraBoardError.message("Jira returned an incomplete issue. No changes were imported.")
        }
        let status = fields["status"]?.jiraObject ?? [:]
        let description = fields["description"] ?? .null
        var details = description.jiraText
        // Rich-text paragraphs add a separator; remove only the final separator,
        // preserving the user's own spaces and trailing blank paragraphs.
        if case .object = description, details.hasSuffix("\n") { details.removeLast() }
        return JiraIssueLink(serverID: serverID, cloudID: site.id, siteURL: site.url, key: key,
            remoteTitle: title, remoteDetails: details,
            remoteUpdated: updated, status: status["name"]?.string ?? "Unknown",
            statusCategory: status["statusCategory"]?.jiraObject["key"]?.string ?? "new")
    }

    func fetch(_ link: JiraIssueLink) async throws -> JiraIssueLink {
        let result = try await call("issue", serverID: link.serverID, arguments: [
            "cloudId": link.cloudID, "issueIdOrKey": link.key, "fields": ["summary", "description", "status", "updated"],
        ])
        return try Self.issue(result, serverID: link.serverID, site: JiraSite(id: link.cloudID, name: "", url: link.siteURL))
    }

    /// Fetch every page before committing, so a failed or truncated response never looks like a successful sync.
    func search(serverID: String, site: JiraSite, jql: String) async throws -> [JiraIssueLink] {
        var issues: [JiraIssueLink] = [], tokens = Set<String>()
        var next: String?
        repeat {
            var arguments: [String: Any] = ["cloudId": site.id, "jql": jql,
                "fields": ["summary", "description", "status", "updated"]]
            if let next { arguments["nextPageToken"] = next }
            let result = try await call("search", serverID: serverID, arguments: arguments).jiraObject
            guard case .array(let page) = result["issues"] else { throw JiraBoardError.message("Jira returned an unreadable search result.") }
            issues += try page.map { try Self.issue($0, serverID: serverID, site: site) }
            guard issues.count <= BoardStore.maximumCards else { throw JiraBoardError.message("This search contains too many issues. Narrow the Jira filter to 1,000 or fewer.") }
            next = result["nextPageToken"]?.string?.nilIfEmpty
            if let next, !tokens.insert(next).inserted { throw JiraBoardError.message("Jira repeated a page. Try syncing again.") }
            if next == nil, result["isLast"]?.boolean == false { throw JiraBoardError.message("Jira did not provide the next page. Try syncing again.") }
        } while next != nil
        return issues
    }

    func publish(_ card: BoardCard) async throws -> JiraIssueLink {
        guard let link = card.jira else { throw JiraBoardError.message("Link this card to Jira first.") }
        let current = try await fetch(link)
        guard current.remoteTitle == link.remoteTitle, current.remoteDetails == link.remoteDetails else {
            throw JiraBoardError.message("This issue changed in Jira. Pull the latest version and resolve any conflicting edits before publishing.")
        }
        var fields: [String: Any] = [:]
        if card.title != link.remoteTitle { fields["summary"] = card.title }
        if card.details != link.remoteDetails {
            fields["description"] = ["type": "doc", "version": 1, "content": card.details.components(separatedBy: "\n").map { line in
                ["type": "paragraph", "content": line.isEmpty ? [] : [["type": "text", "text": line]]] as [String: Any]
            }] as [String: Any]
        }
        if !fields.isEmpty {
            _ = try await call("update", serverID: link.serverID, arguments: ["cloudId": link.cloudID, "issueIdOrKey": link.key, "fields": fields])
        }
        let saved = try await fetch(link)
        guard saved.remoteTitle == card.title, saved.remoteDetails == card.details else {
            throw JiraBoardError.message("Jira did not confirm these changes. Pull the latest issue before publishing again.")
        }
        return saved
    }

    func transitions(_ link: JiraIssueLink) async throws -> [JiraTransition] {
        let result = try await call("transitions", serverID: link.serverID, arguments: ["cloudId": link.cloudID, "issueIdOrKey": link.key])
        return (result.jiraObject["transitions"]?.jiraArray ?? result.jiraArray).compactMap {
            guard let id = $0.jiraObject["id"]?.string, let name = $0.jiraObject["name"]?.string else { return nil }
            return JiraTransition(id: id, name: name)
        }
    }

    func transition(_ link: JiraIssueLink, id: String) async throws -> JiraIssueLink {
        _ = try await call("transition", serverID: link.serverID, arguments: ["cloudId": link.cloudID, "issueIdOrKey": link.key, "transition": ["id": id]])
        return try await fetch(link)
    }
}
