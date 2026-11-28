import Foundation
import Security

struct JiraSite: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var site: String
    var email: String
    var projectKeys: [String] = []

    var host: String { URL(string: site)?.host ?? site }
}

struct JiraTicket: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let summary: String
    let status: String
    let statusCategory: String
    let type: String?
    let assignee: String?
    let url: URL
    let siteName: String
}

enum JiraKeyFinder {
    private static let ignored: Set<String> = ["UTF", "SHA", "ISO", "RFC", "CVE", "GPT", "TLS", "SSL", "HTTP", "MD", "X", "COVID", "ES", "IPV", "AES", "RSA"]
    private static let regex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9])([A-Z][A-Z0-9_]{1,9})-([1-9][0-9]{0,6})(?![A-Za-z0-9])"#)

    static func keys(title: String, branch: String, body: String?) -> [String] {
        var out: [String] = []
        for text in [title, branch.uppercased(), body ?? ""] {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard !ignored.contains(ns.substring(with: match.range(at: 1))) else { continue }
                let key = ns.substring(with: match.range)
                if !out.contains(key) { out.append(key) }
            }
        }
        return out
    }

    static func project(_ key: String) -> String { key.split(separator: "-").first.map(String.init) ?? key }
}

enum JiraError: LocalizedError {
    case badSite, unauthorized, notFound(String), server(Int)

    var errorDescription: String? {
        switch self {
        case .badSite: L("Enter your Jira address, for example acme.atlassian.net")
        case .unauthorized: L("Jira rejected the email or token.")
        case let .notFound(key): String(format: L("%@ wasn't found in your Jira sites."), key)
        case let .server(code): String(format: L("Jira answered with error %d."), code)
        }
    }
}

@MainActor
final class JiraStore: ObservableObject {
    static let shared = JiraStore()

    @Published private(set) var sites: [JiraSite] = []
    @Published private(set) var orgOverrides: [String: String] = [:]
    @Published private(set) var repoOverrides: [String: String] = [:]
    private var learned: [String: String] = [:]
    private var cache: [String: (ticket: JiraTicket, at: Date)] = [:]
    private let defaults = UserDefaults.standard
    private static let service = "com.pullyard.mobile.jira"

    private init() {
        if let data = defaults.data(forKey: "jira.sites"), let items = try? JSONDecoder().decode([JiraSite].self, from: data) { sites = items }
        orgOverrides = defaults.dictionary(forKey: "jira.org") as? [String: String] ?? [:]
        repoOverrides = defaults.dictionary(forKey: "jira.repo") as? [String: String] ?? [:]
        learned = defaults.dictionary(forKey: "jira.learned") as? [String: String] ?? [:]
    }

    var isConfigured: Bool { !sites.isEmpty }

    func importBundle(_ bundle: PYLinkJira) {
        for site in sites where !bundle.connections.contains(where: { $0.id == site.id }) { Self.deleteToken(site.id) }
        sites = bundle.connections.map { JiraSite(id: $0.id, name: $0.name, site: $0.site, email: $0.email, projectKeys: $0.projectKeys) }
        for connection in bundle.connections { Self.saveToken(connection.token, id: connection.id) }
        orgOverrides = bundle.orgOverrides
        repoOverrides = bundle.repoOverrides
        cache = [:]
        save()
    }

    func add(name: String, site rawSite: String, email: String, token: String) async throws {
        guard let base = Self.normalize(rawSite) else { throw JiraError.badSite }
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = JiraREST(base: base, email: trimmedEmail, token: trimmedToken)
        try await client.check()
        let keys = (try? await client.projectKeys()) ?? []
        let id = UUID().uuidString.lowercased()
        Self.saveToken(trimmedToken, id: id)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        sites.append(JiraSite(id: id, name: label.isEmpty ? (base.host ?? "Jira") : label, site: base.absoluteString, email: trimmedEmail, projectKeys: keys))
        save()
    }

    func remove(_ site: JiraSite) {
        Self.deleteToken(site.id)
        sites.removeAll { $0.id == site.id }
        orgOverrides = orgOverrides.filter { $0.value != site.id }
        repoOverrides = repoOverrides.filter { $0.value != site.id }
        learned = learned.filter { $0.value != site.id }
        cache = [:]
        save()
    }

    func route(_ key: String, repo: String?) -> JiraSite? {
        let ids = Set(sites.map(\.id))
        if let repo = repo?.lowercased() {
            if let id = repoOverrides[repo], ids.contains(id) { return site(id) }
            if let owner = repo.split(separator: "/").first.map(String.init), let id = orgOverrides[owner], ids.contains(id) { return site(id) }
        }
        let project = JiraKeyFinder.project(key)
        let owners = sites.filter { $0.projectKeys.contains(project) }
        if owners.count == 1 { return owners[0] }
        if let id = learned[project], ids.contains(id), owners.isEmpty || owners.contains(where: { $0.id == id }) { return site(id) }
        if sites.count == 1 { return sites[0] }
        return nil
    }

    func ticket(_ key: String, repo: String?) async throws -> JiraTicket {
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 120 { return hit.ticket }
        var candidates = sites
        if let routed = route(key, repo: repo) {
            candidates = [routed] + sites.filter { $0.id != routed.id }
        }
        var lastError: Error = JiraError.notFound(key)
        for site in candidates {
            guard let client = client(for: site) else { continue }
            do {
                let ticket = try await client.ticket(key, siteName: site.name)
                learned[JiraKeyFinder.project(key)] = site.id
                defaults.set(learned, forKey: "jira.learned")
                cache[key] = (ticket, Date())
                return ticket
            } catch JiraError.notFound {
                continue
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func site(_ id: String) -> JiraSite? { sites.first { $0.id == id } }

    func client(for site: JiraSite) -> JiraREST? {
        guard let base = URL(string: site.site), let token = Self.loadToken(site.id) else { return nil }
        return JiraREST(base: base, email: site.email, token: token)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: "jira.sites") }
        defaults.set(orgOverrides, forKey: "jira.org")
        defaults.set(repoOverrides, forKey: "jira.repo")
    }

    nonisolated static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard var components = URLComponents(string: text), components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        var path = components.path
        if host.lowercased().hasSuffix(".atlassian.net") {
            path = ""
        } else {
            for marker in ["/browse/", "/secure/", "/projects/", "/issues/", "/rest/", "/plugins/", "/servicedesk/"] {
                if let range = path.range(of: marker) { path = String(path[..<range.lowerBound]) }
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    private static func baseQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    private static func saveToken(_ token: String, id: String) {
        let data = Data(token.utf8)
        if SecItemUpdate(baseQuery(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = baseQuery(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func loadToken(_ id: String) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteToken(_ id: String) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}

struct JiraREST {
    let base: URL
    let email: String
    let token: String

    private var authorization: String {
        email.isEmpty ? "Bearer \(token)" : "Basic " + Data("\(email):\(token)".utf8).base64EncodedString()
    }

    func get(_ path: String) async throws -> Any {
        try await send(path, method: "GET", body: nil)
    }

    @discardableResult
    func send(_ path: String, method: String, body: [String: Any]?) async throws -> Any {
        guard let url = URL(string: base.absoluteString + path) else { throw JiraError.badSite }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data.isEmpty ? [String: Any]() : try JSONSerialization.jsonObject(with: data)
        case 401, 403: throw JiraError.unauthorized
        case 404: throw JiraError.notFound(path)
        default: throw JiraError.server(code)
        }
    }

    func check() async throws {
        _ = try await get("/rest/api/2/myself")
    }

    func projectKeys() async throws -> [String] {
        let object = try await get("/rest/api/2/project")
        return (object as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
    }

    func ticket(_ key: String, siteName: String) async throws -> JiraTicket {
        let object: Any
        do {
            object = try await get("/rest/api/2/issue/\(key)?fields=summary,status,issuetype,assignee")
        } catch JiraError.notFound {
            throw JiraError.notFound(key)
        }
        guard let root = object as? [String: Any], let fields = root["fields"] as? [String: Any] else { throw JiraError.notFound(key) }
        let status = fields["status"] as? [String: Any]
        let category = (status?["statusCategory"] as? [String: Any])?["key"] as? String ?? "new"
        return JiraTicket(
            key: key,
            summary: fields["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            statusCategory: category,
            type: (fields["issuetype"] as? [String: Any])?["name"] as? String,
            assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String,
            url: base.appendingPathComponent("browse").appendingPathComponent(key),
            siteName: siteName
        )
    }
}
