import Foundation

/// A Jira person as the edit pickers need them: how to write them back (`ref`) and how to show them.
struct JiraUser: Identifiable, Hashable, Sendable {
    /// Cloud uses accountId, Jira Server/DC uses name.
    let accountId: String?
    let name: String?
    let displayName: String
    let avatar: String?
    var email: String? = nil
    /// "atlassian" for people; apps and bots have other types and are hidden from pickers.
    var accountType: String? = nil

    var id: String { accountId ?? name ?? displayName }

    var ref: [String: Any] {
        if let accountId { return ["accountId": accountId] }
        return ["name": name ?? displayName]
    }

    nonisolated static func parse(_ o: [String: Any]?) -> JiraUser? {
        guard let o, let display = o["displayName"] as? String else { return nil }
        return JiraUser(accountId: o["accountId"] as? String, name: o["name"] as? String, displayName: display,
                        avatar: (o["avatarUrls"] as? [String: Any])?["48x48"] as? String, email: o["emailAddress"] as? String,
                        accountType: o["accountType"] as? String)
    }
}

struct JiraPriority: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// What the edit panel needs beyond the issue itself.
struct JiraEditInfo: Sendable {
    var priorities: [JiraPriority] = []
    var priorityID: String?
    var assignee: JiraUser?
    var reporter: JiraUser?
    var sprint: JiraSprint?
    /// A board the issue's sprints come from; nil when the project has no scrum board.
    var boardID: Int?
    /// The description as Jira stores it (wiki markup), for editing without losing formatting.
    var rawDescription: String = ""
    var editable: Set<String> = []

    func can(_ field: String) -> Bool { editable.isEmpty || editable.contains(field) }
}

extension JiraClient {
    func editInfo(_ key: String) async throws -> JiraEditInfo {
        async let metaData = request("/rest/api/2/issue/\(key)/editmeta")
        async let issueData = request("/rest/api/2/issue/\(key)?fields=priority,assignee,reporter,description")
        var info = JiraEditInfo()
        let meta = (try? json(try await metaData))?["fields"] as? [String: Any] ?? [:]
        info.editable = Set(meta.keys)
        info.priorities = ((meta["priority"] as? [String: Any])?["allowedValues"] as? [[String: Any]] ?? []).compactMap { v in
            guard let id = v["id"] as? String, let name = v["name"] as? String else { return nil }
            return JiraPriority(id: id, name: name)
        }
        let f = (try json(try await issueData))["fields"] as? [String: Any] ?? [:]
        info.priorityID = (f["priority"] as? [String: Any])?["id"] as? String
        info.assignee = JiraUser.parse(f["assignee"] as? [String: Any])
        info.reporter = JiraUser.parse(f["reporter"] as? [String: Any])
        info.rawDescription = f["description"] as? String ?? ""
        // Sprint comes from the agile API; boards without sprints just have none.
        if let agile = try? json(try await request("/rest/agile/1.0/issue/\(key)?fields=sprint,closedSprints")),
           let af = agile["fields"] as? [String: Any] {
            if let s = af["sprint"] as? [String: Any], let id = s["id"] as? Int, let name = s["name"] as? String {
                info.sprint = JiraSprint(id: id, name: name, endDate: (s["endDate"] as? String).flatMap(JiraClient.parseDate))
                info.boardID = s["originBoardId"] as? Int
            } else if let closed = (af["closedSprints"] as? [[String: Any]])?.last {
                info.boardID = closed["originBoardId"] as? Int
            }
        }
        return info
    }

    /// People for the pickers. Assignee: who can be assigned the issue. Reporter: anyone on the site.
    /// Jira Cloud rejects `username` (GDPR mode) and Server ignores `query`, so try one then the other.
    func users(for key: String, query: String, assignable: Bool = true) async throws -> [JiraUser] {
        let q = Self.encode(query)
        let paths: [String]
        if assignable || query.isEmpty {
            paths = ["/rest/api/2/user/assignable/search?issueKey=\(key)&query=\(q)&maxResults=40",
                     "/rest/api/2/user/assignable/search?issueKey=\(key)&username=\(q)&maxResults=40"]
        } else {
            paths = ["/rest/api/2/user/search?query=\(q)&maxResults=40",
                     "/rest/api/2/user/search?username=\(q)&maxResults=40"]
        }
        var lastError: Error?
        for path in paths {
            do {
                let data = try await request(path)
                let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
                let users = list.compactMap(JiraUser.parse).filter { ($0.accountType ?? "atlassian") == "atlassian" }
                if users.isEmpty, path != paths.last, query.isEmpty == false { continue }
                return users
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError(message: "Couldn't search Jira people")
    }

    func update(_ key: String, fields: [String: Any]) async throws {
        _ = try await request("/rest/api/2/issue/\(key)", method: "PUT", body: ["fields": fields])
    }

    func assign(_ key: String, to user: JiraUser?) async throws {
        let body: [String: Any] = user?.ref ?? ["accountId": NSNull()]
        _ = try await request("/rest/api/2/issue/\(key)/assignee", method: "PUT", body: body)
    }

    func sprints(board: Int) async throws -> [JiraSprint] {
        let o = try json(try await request("/rest/agile/1.0/board/\(board)/sprint?state=active,future&maxResults=50"))
        return (o["values"] as? [[String: Any]] ?? []).compactMap { v in
            guard let id = v["id"] as? Int, let name = v["name"] as? String else { return nil }
            return JiraSprint(id: id, name: name, endDate: (v["endDate"] as? String).flatMap(JiraClient.parseDate))
        }
    }

    /// Moves the issue into `sprint`, or to the backlog when nil.
    func move(_ key: String, toSprint sprint: Int?) async throws {
        if let sprint {
            _ = try await request("/rest/agile/1.0/sprint/\(sprint)/issue", method: "POST", body: ["issues": [key]])
        } else {
            _ = try await request("/rest/agile/1.0/backlog/issue", method: "POST", body: ["issues": [key]])
        }
    }
}
