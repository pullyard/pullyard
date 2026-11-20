import Foundation

struct GitRemote: Hashable, Sendable {
    enum Kind: String, Sendable {
        case github, gitlab, bitbucket, other
    }

    let host: String
    let path: String
    let kind: Kind

    init(host: String, path: String, kind: Kind) {
        self.host = host
        self.path = path
        self.kind = kind
    }

    init(host: String, path: String) {
        self.init(host: host, path: path, kind: Self.kind(host: host))
    }

    static func kind(host: String) -> Kind {
        let h = host.lowercased()
        if h.contains("github") { return .github }
        if h.contains("gitlab") { return .gitlab }
        if h.contains("bitbucket") { return .bitbucket }
        return .other
    }

    var webURL: String { "https://\(host)/\(path)" }

    var githubRepo: RepoRef? { host.lowercased() == "github.com" ? RepoRef(full: path) : nil }

    var noun: String { requestNoun(kind) }

    var service: String {
        switch kind {
        case .gitlab: return "GitLab"
        case .bitbucket: return "Bitbucket"
        case .github, .other: return host
        }
    }

    func kind(for provider: GitProvider?) -> Kind {
        switch provider {
        case .github?, .githubEnterprise?: return .github
        case .gitlab?: return .gitlab
        case .bitbucket?: return .bitbucket
        case .gitea?: return .other
        case nil: return kind
        }
    }

    func with(kind: Kind) -> GitRemote { GitRemote(host: host, path: path, kind: kind) }

    func requestNoun(_ kind: Kind) -> String { kind == .gitlab ? "merge request" : "pull request" }

    func newRequestURL(branch: String) -> String {
        kind == .other ? webURL : newRequestURL(branch: branch, kind: kind)
    }

    func newRequestURL(branch: String, kind: Kind) -> String {
        let b = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? branch
        switch kind {
        case .github: return "\(webURL)/pull/new/\(b)"
        case .gitlab: return "\(webURL)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(b)"
        case .bitbucket: return "\(webURL)/pull-requests/new?source=\(b)"
        case .other: return "\(webURL)/pulls"
        }
    }

    static func parse(_ raw: String) -> GitRemote? {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix(".git") { url.removeLast(4) }
        var host: String
        var path: String
        if let comps = URLComponents(string: url), let h = comps.host, comps.scheme != nil {
            host = h
            path = comps.path
        } else if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            host = String(url[url.index(after: at)..<colon])
            path = String(url[url.index(after: colon)...])
        } else if !url.contains("://"), let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            host = String(url[..<colon])
            path = String(url[url.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "ssh.github.com" { host = "github.com" }
        if host.hasPrefix("altssh.") { host = String(host.dropFirst(7)) }
        if host == "bitbucket.org", path.hasPrefix("scm/") { path = String(path.dropFirst(4)) }
        guard !host.isEmpty, path.contains("/") else { return nil }
        return GitRemote(host: host, path: path)
    }
}
