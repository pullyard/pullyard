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
}

struct JiraTransition: Identifiable, Equatable {
    let id: String
    let name: String
    let to: String
    let toCategory: String
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

@Observable
@MainActor
final class JiraAccount {
    static let shared = JiraAccount()
    private static let keychainAccount = "jira-token"

    var site: String { didSet { UserDefaults.standard.set(site, forKey: "jira.site") } }
    var email: String { didSet { UserDefaults.standard.set(email, forKey: "jira.email") } }
    private(set) var hasToken: Bool
    var displayName: String?

    private init() {
        site = UserDefaults.standard.string(forKey: "jira.site") ?? ""
        email = UserDefaults.standard.string(forKey: "jira.email") ?? ""
        if UserDefaults.standard.object(forKey: "jira.hasToken") == nil, !(UserDefaults.standard.string(forKey: "jira.site") ?? "").isEmpty {
            UserDefaults.standard.set(Keychain.load(account: Self.keychainAccount) != nil, forKey: "jira.hasToken")
        }
        hasToken = UserDefaults.standard.bool(forKey: "jira.hasToken")
        displayName = UserDefaults.standard.string(forKey: "jira.name")
    }

    var isConfigured: Bool { baseURL != nil && hasToken }

    var baseURL: URL? { Self.normalizedSite(site) }

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

    func connect(site: String, email: String, token: String) async throws {
        self.site = Self.normalizedSite(site)?.absoluteString ?? site
        self.email = email.trimmingCharacters(in: .whitespaces)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = baseURL else { throw APIError(message: "Enter your Jira address, for example acme.atlassian.net") }
        let client = JiraClient(base: base, authorization: Self.authorization(email: self.email, token: t))
        let name = try await client.myself()
        try Keychain.save(t, account: Self.keychainAccount)
        self.token = t
        hasToken = true
        UserDefaults.standard.set(true, forKey: "jira.hasToken")
        issueCache = [:]
        displayName = name
        UserDefaults.standard.set(name, forKey: "jira.name")
    }

    func disconnect() {
        Keychain.delete(account: Self.keychainAccount)
        token = nil
        hasToken = false
        UserDefaults.standard.set(false, forKey: "jira.hasToken")
        issueCache = [:]
        displayName = nil
        UserDefaults.standard.removeObject(forKey: "jira.name")
    }

    nonisolated static func authorization(email: String, token: String) -> String {
        email.isEmpty ? "Bearer \(token)" : "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var issueCache: [String: (issue: JiraIssue, at: Date)] = [:]

    func client() -> JiraClient? {
        guard hasToken, let base = baseURL else { return nil }
        if token == nil { token = Keychain.load(account: Self.keychainAccount) }
        guard let token else { return nil }
        return JiraClient(base: base, authorization: Self.authorization(email: email, token: token))
    }

    func cachedIssue(_ key: String) -> JiraIssue? {
        guard let hit = issueCache[key], Date().timeIntervalSince(hit.at) < 60 else { return nil }
        return hit.issue
    }

    func clearCache() {
        issueCache = [:]
    }

    func remember(_ issue: JiraIssue) {
        issueCache[issue.key] = (issue, Date())
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

    func myself() async throws -> String {
        let o = try json(try await request("/rest/api/2/myself"))
        return o["displayName"] as? String ?? o["name"] as? String ?? "Jira"
    }

    func issue(_ key: String) async throws -> JiraIssue {
        let fields = "summary,status,issuetype,priority,assignee,reporter,description,updated,parent"
        let o = try json(try await request("/rest/api/2/issue/\(key)?fields=\(fields)&expand=renderedFields"))
        return Self.parseIssue(o, base: base)
    }

    func transitions(_ key: String) async throws -> [JiraTransition] {
        let o = try json(try await request("/rest/api/2/issue/\(key)/transitions"))
        return (o["transitions"] as? [[String: Any]] ?? []).compactMap { t in
            guard let id = t["id"] as? String, let name = t["name"] as? String else { return nil }
            let to = t["to"] as? [String: Any]
            return JiraTransition(id: id, name: name, to: to?["name"] as? String ?? name,
                                  toCategory: ((to?["statusCategory"] as? [String: Any])?["key"] as? String) ?? "")
        }
    }

    func transition(_ key: String, to id: String) async throws {
        _ = try await request("/rest/api/2/issue/\(key)/transitions", method: "POST", body: ["transition": ["id": id]])
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
            parentSummary: ((f["parent"] as? [String: Any])?["fields"] as? [String: Any])?["summary"] as? String
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
