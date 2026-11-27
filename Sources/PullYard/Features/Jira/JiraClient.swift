import Foundation

struct JiraIssue: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let summary: String
    let status: String
    let statusCategory: String
    let type: String?
    let priority: String?
    let assignee: String?
    let assigneeAvatar: String?
    let reporter: String?
    let description: String
    let url: String
    let updated: Date?
    var parentKey: String? = nil
    var parentSummary: String? = nil
    var attachments: [JiraAttachment] = []
    var connectionID: String? = nil
    var statusID: String? = nil
    var labels: [String] = []

    var siteBase: String {
        guard let r = url.range(of: "/browse/") else { return url }
        return String(url[..<r.lowerBound])
    }
}

struct JiraAttachment: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: Equatable, Sendable { case image, video, other }

    let id: String
    let filename: String
    let mimeType: String
    let size: Int
    let content: String
    let thumbnail: String?
    let author: String?
    let created: Date?

    var kind: Kind {
        let mime = mimeType.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"].contains(ext) { return .image }
        if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "avi", "mkv", "3gp"].contains(ext) { return .video }
        return .other
    }

    var isMedia: Bool { kind != .other }
}

struct JiraTransition: Identifiable, Equatable {
    let id: String
    let name: String
    let to: String
    let toCategory: String
    var toID: String? = nil
}

enum JiraKeys {
    private static let ignored: Set<String> = ["UTF", "SHA", "ISO", "RFC", "CVE", "GPT", "TLS", "SSL", "HTTP", "MD", "X", "COVID", "ES", "IPV", "AES", "RSA"]

    private static let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Z][A-Z0-9_]{1,9})-([1-9][0-9]{0,6})(?![A-Za-z0-9])"#)

    static func extract(_ texts: [String]) -> [String] {
        var seen: [String] = []
        for text in texts {
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let project = ns.substring(with: m.range(at: 1))
                guard !ignored.contains(project) else { continue }
                let key = ns.substring(with: m.range)
                if !seen.contains(key) { seen.append(key) }
            }
        }
        return seen
    }

    static func extract(branch: String) -> [String] {
        extract([branch.uppercased()])
    }

    static func detected(title: String, branch: String, body: String) -> [String] {
        var out: [String] = []
        for k in extract([title]) + extract(branch: branch) + extract([body]) where !out.contains(k) { out.append(k) }
        return out
    }
}

struct JiraConnection: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var site: String
    var email: String
    var displayName: String?
    var projectKeys: [String] = []
    var projectsUpdated: Date?

    var baseURL: URL? { JiraConnections.normalizedSite(site) }
    var host: String { baseURL?.host ?? site }
}

struct JiraLinkConnection: Hashable {
    let id: String
    let name: String
    let site: String
    let email: String
}

enum JiraRouteSource: Equatable {
    case repoOverride, orgOverride, project, learned, only
}

@Observable
@MainActor
final class JiraConnections {
    static let shared = JiraConnections()
    private static let listKey = "jira.connections"
    private static let orgKey = "jira.overrides.org"
    private static let repoKey = "jira.overrides.repo"
    private static let learnedKey = "jira.learned"
    private static let legacyKeychainAccount = "jira-token"

    private(set) var connections: [JiraConnection]
    private(set) var orgOverrides: [String: String]
    private(set) var repoOverrides: [String: String]
    @ObservationIgnored private var learned: [String: String]
    @ObservationIgnored private var tokens: [String: String] = [:]
    @ObservationIgnored private var issueCache: [String: [String: (issue: JiraIssue, at: Date)]] = [:]

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.listKey), let list = try? JSONDecoder().decode([JiraConnection].self, from: data) {
            connections = list
        } else {
            connections = []
        }
        orgOverrides = defaults.dictionary(forKey: Self.orgKey) as? [String: String] ?? [:]
        repoOverrides = defaults.dictionary(forKey: Self.repoKey) as? [String: String] ?? [:]
        learned = defaults.dictionary(forKey: Self.learnedKey) as? [String: String] ?? [:]
        migrateLegacy()
    }

    static func keychainAccount(_ id: String) -> String { "jira-token.\(id)" }

    private func migrateLegacy() {
        let defaults = UserDefaults.standard
        guard connections.isEmpty, let site = defaults.string(forKey: "jira.site"), !site.isEmpty, defaults.object(forKey: Self.listKey) == nil else { return }
        guard let token = Keychain.load(account: Self.legacyKeychainAccount) else { return }
        let id = UUID().uuidString.lowercased()
        let name = Self.normalizedSite(site)?.host.map(Self.shortName) ?? "Jira"
        guard (try? Keychain.save(token, account: Self.keychainAccount(id))) != nil else { return }
        connections = [JiraConnection(id: id, name: name, site: site, email: defaults.string(forKey: "jira.email") ?? "", displayName: defaults.string(forKey: "jira.name"))]
        save()
        Keychain.delete(account: Self.legacyKeychainAccount)
        defaults.removeObject(forKey: "jira.hasToken")
        Task { await refreshProjects(id) }
    }

    nonisolated static func shortName(_ host: String) -> String {
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    var isConfigured: Bool { !connections.isEmpty }
    var hasSeveral: Bool { connections.count > 1 }

    func connection(_ id: String?) -> JiraConnection? {
        guard let id else { return nil }
        return connections.first { $0.id == id }
    }

    var linkConnections: [JiraLinkConnection] {
        connections.map { JiraLinkConnection(id: $0.id, name: $0.name, site: $0.baseURL?.absoluteString ?? $0.site, email: $0.email) }
    }

    func token(for id: String) -> String? {
        if let cached = tokens[id] { return cached }
        let value = Keychain.load(account: Self.keychainAccount(id))
        tokens[id] = value
        return value
    }

    func client(for id: String?) -> JiraClient? {
        guard let c = connection(id), let base = c.baseURL, let token = token(for: c.id) else { return nil }
        return JiraClient(base: base, authorization: Self.authorization(email: c.email, token: token))
    }

    @discardableResult
    func add(name: String, site: String, email: String, token: String) async throws -> JiraConnection {
        let id = UUID().uuidString.lowercased()
        let connection = try await validated(id: id, name: name, site: site, email: email, token: token)
        connections.append(connection)
        save()
        await refreshProjects(id)
        return self.connection(id) ?? connection
    }

    func update(_ id: String, name: String, site: String, email: String, token: String?) async throws {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = (t?.isEmpty == false ? t : nil) ?? self.token(for: id) ?? ""
        var updated = try await validated(id: id, name: name, site: site, email: email, token: secret)
        updated.projectKeys = connections[index].projectKeys
        updated.projectsUpdated = connections[index].projectsUpdated
        connections[index] = updated
        issueCache[id] = nil
        save()
        await refreshProjects(id)
    }

    func remove(_ id: String) {
        Keychain.delete(account: Self.keychainAccount(id))
        tokens[id] = nil
        issueCache[id] = nil
        connections.removeAll { $0.id == id }
        orgOverrides = orgOverrides.filter { $0.value != id }
        repoOverrides = repoOverrides.filter { $0.value != id }
        learned = learned.filter { $0.value != id }
        save()
    }

    private func validated(id: String, name: String, site: String, email: String, token: String) async throws -> JiraConnection {
        let normalized = Self.normalizedSite(site)?.absoluteString ?? site
        let mail = email.trimmingCharacters(in: .whitespaces)
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = Self.normalizedSite(normalized) else { throw APIError(message: "Enter your Jira address, for example acme.atlassian.net") }
        guard !secret.isEmpty else { throw APIError(message: "Enter an API token") }
        let client = JiraClient(base: base, authorization: Self.authorization(email: mail, token: secret))
        let me = try await client.myself()
        try Keychain.save(secret, account: Self.keychainAccount(id))
        tokens[id] = secret
        let label = name.trimmingCharacters(in: .whitespaces)
        return JiraConnection(id: id, name: label.isEmpty ? Self.shortName(base.host ?? "Jira") : label, site: normalized, email: mail, displayName: me)
    }

    func refreshProjects(_ id: String) async {
        guard let client = client(for: id) else { return }
        guard let keys = try? await client.projectKeys() else { return }
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].projectKeys = keys.sorted()
        connections[index].projectsUpdated = Date()
        save()
    }

    func refreshAllProjects(olderThan age: TimeInterval = 0) async {
        for c in connections where Date().timeIntervalSince(c.projectsUpdated ?? .distantPast) >= age {
            await refreshProjects(c.id)
        }
    }

    nonisolated static func projectKey(of issueKey: String) -> String {
        issueKey.split(separator: "-").first.map { String($0).uppercased() } ?? issueKey.uppercased()
    }

    func resolve(issueKey: String, repo: RepoRef?) -> String? {
        route(issueKey: issueKey, repo: repo)?.id
    }

    func route(issueKey: String, repo: RepoRef?) -> (id: String, source: JiraRouteSource)? {
        Self.route(issueKey: issueKey, repo: repo, connections: connections, orgOverrides: orgOverrides, repoOverrides: repoOverrides, learned: learned)
    }

    nonisolated static func route(issueKey: String, repo: RepoRef?, connections: [JiraConnection], orgOverrides: [String: String], repoOverrides: [String: String], learned: [String: String]) -> (id: String, source: JiraRouteSource)? {
        let ids = Set(connections.map(\.id))
        if let repo {
            if let id = repoOverrides[repo.full.lowercased()], ids.contains(id) { return (id, .repoOverride) }
            if let id = orgOverrides[repo.owner.lowercased()], ids.contains(id) { return (id, .orgOverride) }
        }
        let project = projectKey(of: issueKey)
        let owners = connections.filter { $0.projectKeys.contains(project) }
        if owners.count == 1 { return (owners[0].id, .project) }
        if let id = learned[project], ids.contains(id), owners.isEmpty || owners.contains(where: { $0.id == id }) { return (id, .learned) }
        if connections.count == 1 { return (connections[0].id, .only) }
        return nil
    }

    func override(for repo: RepoRef) -> (repo: String?, org: String?) {
        (repoOverrides[repo.full.lowercased()], orgOverrides[repo.owner.lowercased()])
    }

    func setRepoOverride(_ id: String?, for repo: RepoRef) {
        repoOverrides[repo.full.lowercased()] = id
        save()
    }

    func setOrgOverride(_ id: String?, for org: String) {
        orgOverrides[org.lowercased()] = id
        save()
    }

    func connectionForRepo(_ repo: RepoRef) -> String? {
        repoOverrides[repo.full.lowercased()] ?? orgOverrides[repo.owner.lowercased()] ?? (connections.count == 1 ? connections.first?.id : nil)
    }

    func fetchIssue(_ key: String, repo: RepoRef?) async throws -> JiraIssue {
        if let id = resolve(issueKey: key, repo: repo), let client = client(for: id) {
            var issue = try await client.issue(key)
            issue.connectionID = id
            remember(issue)
            return issue
        }
        var lastError: Error = APIError(message: "No Jira connection has \(key)")
        for c in connections {
            guard let client = client(for: c.id) else { continue }
            do {
                var issue = try await client.issue(key)
                issue.connectionID = c.id
                learned[Self.projectKey(of: key)] = c.id
                save()
                remember(issue)
                return issue
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func cachedIssue(_ key: String, repo: RepoRef?) -> JiraIssue? {
        let ids = resolve(issueKey: key, repo: repo).map { [$0] } ?? connections.map(\.id)
        for id in ids {
            if let hit = issueCache[id]?[key], Date().timeIntervalSince(hit.at) < 60 { return hit.issue }
        }
        return nil
    }

    func remember(_ issue: JiraIssue) {
        guard let id = issue.connectionID else { return }
        issueCache[id, default: [:]][issue.key] = (issue, Date())
    }

    func clearCache() {
        issueCache = [:]
    }

    func linkedKeys(for prURL: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "jira.links." + prURL) ?? []
    }

    func setLinkedKeys(_ keys: [String], for prURL: String) {
        UserDefaults.standard.set(keys, forKey: "jira.links." + prURL)
    }

    func hiddenKeys(for prURL: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "jira.hidden." + prURL) ?? []
    }

    func setHiddenKeys(_ keys: [String], for prURL: String) {
        if keys.isEmpty { UserDefaults.standard.removeObject(forKey: "jira.hidden." + prURL) } else { UserDefaults.standard.set(keys, forKey: "jira.hidden." + prURL) }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(connections) { defaults.set(data, forKey: Self.listKey) }
        defaults.set(orgOverrides, forKey: Self.orgKey)
        defaults.set(repoOverrides, forKey: Self.repoKey)
        defaults.set(learned, forKey: Self.learnedKey)
    }

    nonisolated static func normalizedSite(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard var c = URLComponents(string: s), c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty else { return nil }
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        var path = c.path
        if host.lowercased().hasSuffix(".atlassian.net") {
            path = ""
        } else {
            for marker in ["/browse/", "/secure/", "/projects/", "/issues/", "/rest/", "/plugins/", "/servicedesk/"] {
                if let r = path.range(of: marker) { path = String(path[..<r.lowerBound]) }
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        return c.url
    }

    nonisolated static func authorization(email: String, token: String) -> String {
        email.isEmpty ? "Bearer \(token)" : "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }
}

final class JiraRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme == "https" else { return nil }
        var next = request
        if request.url?.host != task.originalRequest?.url?.host {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }
}

struct JiraClient: Sendable {
    let base: URL
    let authorization: String

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: base.absoluteString + path), url.host == base.host, url.scheme == "https" else {
            throw APIError(message: "Invalid Jira address")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (obj?["errorMessages"] as? [String])?.first ?? (obj?["message"] as? String)
            switch status {
            case 401: throw APIError(message: "Jira rejected the credentials (401). Check the email and API token.", status: 401)
            case 403: throw APIError(message: message ?? "No permission in Jira (403)", status: 403)
            case 404: throw APIError(message: message ?? "Not found in Jira (404)", status: 404)
            default: throw APIError(message: "Jira \(status): \(message ?? HTTPURLResponse.localizedString(forStatusCode: status))", status: status)
            }
        }
        return data
    }

    private func json(_ data: Data) throws -> [String: Any] {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError(message: "Jira sent a web page instead of data. Check the address: it should be just your site, like acme.atlassian.net.")
        }
        return o
    }

    func projectKeys() async throws -> [String] {
        var keys: [String] = []
        var start = 0
        do {
            while true {
                let o = try json(try await request("/rest/api/3/project/search?startAt=\(start)&maxResults=50"))
                let values = o["values"] as? [[String: Any]] ?? []
                keys += values.compactMap { $0["key"] as? String }
                let total = o["total"] as? Int ?? keys.count
                start += values.count
                if values.isEmpty || o["isLast"] as? Bool == true || start >= total || start > 5000 { break }
            }
            return keys
        } catch let error as APIError where error.status == 404 {
            let data = try await request("/rest/api/2/project")
            let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            return list.compactMap { $0["key"] as? String }
        }
    }

    func myself() async throws -> String {
        let o = try json(try await request("/rest/api/2/myself"))
        return o["displayName"] as? String ?? o["name"] as? String ?? "Jira"
    }

    func issue(_ key: String) async throws -> JiraIssue {
        let fields = "summary,status,issuetype,priority,assignee,reporter,description,updated,parent,attachment"
        let o = try json(try await request("/rest/api/2/issue/\(key)?fields=\(fields)&expand=renderedFields"))
        return Self.parseIssue(o, base: base)
    }

    func transitions(_ key: String) async throws -> [JiraTransition] {
        let o = try json(try await request("/rest/api/2/issue/\(key)/transitions"))
        return (o["transitions"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            let to = t["to"] as? [String: Any]
            return JiraTransition(id: id, name: name, to: to?["name"] as? String ?? name,
                                  toCategory: ((to?["statusCategory"] as? [String: Any])?["key"] as? String) ?? "",
                                  toID: to?["id"] as? String)
        }
    }

    func transition(_ key: String, to id: String) async throws {
        _ = try await request("/rest/api/2/issue/\(key)/transitions", method: "POST", body: ["transition": ["id": id]])
    }

    func data(at link: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: try attachmentRequest(link), delegate: JiraRedirectGuard())
        try Self.check(response)
        return data
    }

    func download(at link: String, to destination: URL) async throws {
        let (temp, response) = try await URLSession.shared.download(for: try attachmentRequest(link), delegate: JiraRedirectGuard())
        defer { try? FileManager.default.removeItem(at: temp) }
        try Self.check(response)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
    }

    private func attachmentRequest(_ link: String) throws -> URLRequest {
        guard let url = URL(string: link), url.scheme == "https", url.host == base.host else {
            throw APIError(message: "Attachment is not on this Jira site")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        return req
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError(message: status == 403 ? "No permission to open this attachment (403)" : "Jira \(status): couldn't load the attachment", status: status)
        }
    }

    func comment(_ key: String, body: String) async throws {
        _ = try await request("/rest/api/2/issue/\(key)/comment", method: "POST", body: ["body": body])
    }

    nonisolated static func parseIssue(_ o: [String: Any], base: URL) -> JiraIssue {
        let key = o["key"] as? String ?? ""
        let f = o["fields"] as? [String: Any] ?? [:]
        let status = f["status"] as? [String: Any]
        let rendered = (o["renderedFields"] as? [String: Any])?["description"] as? String
        let assignee = f["assignee"] as? [String: Any]
        let updated = (f["updated"] as? String).flatMap { s in isoFormatter.date(from: s.replacingOccurrences(of: #"([+-]\d\d)(\d\d)$"#, with: "$1:$2", options: .regularExpression)) }
        return JiraIssue(
            key: key,
            summary: f["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            statusCategory: ((status?["statusCategory"] as? [String: Any])?["key"] as? String) ?? "",
            type: (f["issuetype"] as? [String: Any])?["name"] as? String,
            priority: (f["priority"] as? [String: Any])?["name"] as? String,
            assignee: assignee?["displayName"] as? String,
            assigneeAvatar: (assignee?["avatarUrls"] as? [String: Any])?["48x48"] as? String,
            reporter: (f["reporter"] as? [String: Any])?["displayName"] as? String,
            description: rendered.map(plainText) ?? (f["description"] as? String ?? ""),
            url: base.absoluteString + "/browse/" + key,
            updated: updated,
            parentKey: (f["parent"] as? [String: Any])?["key"] as? String,
            parentSummary: ((f["parent"] as? [String: Any])?["fields"] as? [String: Any])?["summary"] as? String,
            attachments: (f["attachment"] as? [[String: Any]] ?? []).compactMap(parseAttachment),
            statusID: status?["id"] as? String,
            labels: f["labels"] as? [String] ?? []
        )
    }

    nonisolated static func parseAttachment(_ a: [String: Any]) -> JiraAttachment? {
        let id = (a["id"] as? String) ?? (a["id"] as? Int).map(String.init)
        guard let id, let content = a["content"] as? String else { return nil }
        let created = (a["created"] as? String).flatMap { s in isoFormatter.date(from: s.replacingOccurrences(of: #"([+-]\d\d)(\d\d)$"#, with: "$1:$2", options: .regularExpression)) }
        return JiraAttachment(
            id: id,
            filename: a["filename"] as? String ?? "attachment",
            mimeType: a["mimeType"] as? String ?? "",
            size: (a["size"] as? Int) ?? 0,
            content: content,
            thumbnail: a["thumbnail"] as? String,
            author: (a["author"] as? [String: Any])?["displayName"] as? String,
            created: created
        )
    }

    nonisolated private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated static func plainText(_ html: String) -> String {
        var s = collapseWhitespace(html)
        let rules: [(String, String)] = [
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|h[1-6]|tr|table|blockquote|pre)>", "\n"),
            ("(?i)<li[^>]*>", "\n• "),
            ("(?i)</t[dh]>", " · "),
            ("(?i)<[^>]+>", "")
        ]
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "[ \\t\\x{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            while l.hasSuffix("·") { l = String(l.dropLast()).trimmingCharacters(in: .whitespaces) }
            while l.hasPrefix("·") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return l
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last?.isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").replacingOccurrences(of: "\u{1}", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static let preBlock = try! NSRegularExpression(pattern: "(?is)<pre[^>]*>.*?</pre>")

    nonisolated private static func collapseWhitespace(_ html: String) -> String {
        let ns = html as NSString
        var out = ""
        var last = 0
        for m in preBlock.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            out += ns.substring(with: m.range).replacingOccurrences(of: "\n", with: "\u{1}")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out
    }
}

// MARK: - Agile boards

struct JiraBoard: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let type: String
    let projectKey: String?

    var isScrum: Bool { type.lowercased() == "scrum" }
}

struct JiraBoardColumn: Identifiable, Hashable, Sendable {
    let name: String
    let statusIDs: [String]
    var id: String { name }
}

struct JiraSprint: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let endDate: Date?
}

extension JiraClient {
    static let boardIssueFields = "summary,status,issuetype,priority,assignee,updated,labels,parent"

    func boards() async throws -> [JiraBoard] {
        var out: [JiraBoard] = []
        var start = 0
        while true {
            let o = try json(try await request("/rest/agile/1.0/board?startAt=\(start)&maxResults=50"))
            let values = o["values"] as? [[String: Any]] ?? []
            out += values.compactMap { v in
                guard let id = v["id"] as? Int, let name = v["name"] as? String else { return nil }
                return JiraBoard(id: id, name: name, type: v["type"] as? String ?? "",
                                 projectKey: (v["location"] as? [String: Any])?["projectKey"] as? String)
            }
            start += values.count
            if values.isEmpty || o["isLast"] as? Bool == true || start >= 1000 { break }
        }
        return out
    }

    func columns(board: Int) async throws -> [JiraBoardColumn] {
        let o = try json(try await request("/rest/agile/1.0/board/\(board)/configuration"))
        let columns = (o["columnConfig"] as? [String: Any])?["columns"] as? [[String: Any]] ?? []
        return columns.compactMap { c in
            guard let name = c["name"] as? String else { return nil }
            let ids = (c["statuses"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String) ?? ($0["id"] as? Int).map(String.init) }
            return JiraBoardColumn(name: name, statusIDs: ids)
        }
    }

    func activeSprints(board: Int) async throws -> [JiraSprint] {
        let o = try json(try await request("/rest/agile/1.0/board/\(board)/sprint?state=active"))
        return (o["values"] as? [[String: Any]] ?? []).compactMap { v in
            guard let id = v["id"] as? Int, let name = v["name"] as? String else { return nil }
            let end = (v["endDate"] as? String).flatMap { JiraClient.parseDate($0) }
            return JiraSprint(id: id, name: name, endDate: end)
        }
    }

    /// Issues on a board: the sprint's issues for a scrum board, or open and recently finished ones for kanban.
    func boardIssues(board: Int, sprint: Int?) async throws -> [JiraIssue] {
        let path: String
        if let sprint {
            path = "/rest/agile/1.0/board/\(board)/sprint/\(sprint)/issue"
        } else {
            path = "/rest/agile/1.0/board/\(board)/issue"
        }
        var query = "fields=\(Self.boardIssueFields)"
        if sprint == nil {
            query += "&jql=" + Self.encode("statusCategory != Done OR updated >= -14d")
        }
        var out: [JiraIssue] = []
        var start = 0
        while true {
            let o = try json(try await request("\(path)?\(query)&startAt=\(start)&maxResults=100"))
            let issues = o["issues"] as? [[String: Any]] ?? []
            out += issues.map { Self.parseIssue($0, base: base) }
            start += issues.count
            let total = o["total"] as? Int ?? out.count
            if issues.isEmpty || start >= total || start >= 1000 { break }
        }
        return out
    }

    nonisolated static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        let fixed = s.replacingOccurrences(of: #"([+-]\d\d)(\d\d)$"#, with: "$1:$2", options: .regularExpression)
        return isoFormatter.date(from: fixed) ?? ISO8601DateFormatter().date(from: fixed)
    }
}
