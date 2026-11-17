import Foundation

struct GitRemote: Hashable, Sendable {
    enum Kind: String, Sendable {
        case github, gitlab, bitbucket, other
    }

    let host: String
    let path: String

    var kind: Kind {
        let h = host.lowercased()
        if h.contains("github") { return .github }
        if h.contains("gitlab") { return .gitlab }
        if h.contains("bitbucket") { return .bitbucket }
        return .other
    }

    var webURL: String { "https://\(host)/\(path)" }

    var repo: RepoRef? { host.lowercased() == "github.com" ? RepoRef(full: path) : nil }

    func kind(for provider: GitProvider?) -> Kind {
        switch provider {
        case .github?, .githubEnterprise?: return .github
        case .gitlab?: return .gitlab
        case .bitbucket?: return .bitbucket
        case .gitea?: return .other
        case nil: return kind
        }
    }

    func requestNoun(_ kind: Kind) -> String { kind == .gitlab ? "merge request" : "pull request" }

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
        var host = ""
        var path = ""
        if let scheme = url.range(of: "://") {
            url = String(url[scheme.upperBound...])
            guard let slash = url.firstIndex(of: "/") else { return nil }
            host = String(url[..<slash])
            path = String(url[url.index(after: slash)...])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
            if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        } else if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            host = String(url[..<colon])
            path = String(url[url.index(after: colon)...])
            if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        } else {
            return nil
        }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard !host.isEmpty, path.contains("/") else { return nil }
        return GitRemote(host: host, path: path)
    }
}
