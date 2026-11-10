import SwiftUI

struct GitRemote: Equatable {
    enum Kind: Equatable { case github, gitlab, bitbucket, other }

    let host: String
    let path: String
    let kind: Kind

    var githubRepo: RepoRef? { host == "github.com" ? RepoRef(full: path) : nil }
    var webURL: String { "https://\(host)/\(path)" }

    var noun: String { kind == .gitlab ? "merge request" : "pull request" }

    func newRequestURL(branch: String) -> String {
        let b = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
        switch kind {
        case .github: return "\(webURL)/pull/new/\(b)"
        case .gitlab: return "\(webURL)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(b)"
        case .bitbucket: return "\(webURL)/pull-requests/new?source=\(b)"
        case .other: return webURL
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
        } else {
            return nil
        }
        host = host.lowercased()
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if host == "ssh.github.com" { host = "github.com" }
        if host.hasPrefix("altssh.") { host = String(host.dropFirst(7)) }
        if host == "bitbucket.org", path.hasPrefix("scm/") { path = String(path.dropFirst(4)) }
        guard !host.isEmpty, path.contains("/") else { return nil }
        let kind: Kind
        if host == "github.com" || host.contains("github") {
            kind = .github
        } else if host.contains("gitlab") {
            kind = .gitlab
        } else if host == "bitbucket.org" || host.contains("bitbucket") {
            kind = .bitbucket
        } else {
            kind = .other
        }
        return GitRemote(host: host, path: path, kind: kind)
    }
}

enum AgentShip {
    static func openPRPrompt(branch: String, defaultBranch: String?, hasChanges: Bool, ahead: Int, remote: GitRemote? = nil) -> String {
        let onDefault = defaultBranch.map { $0 == branch } ?? ["main", "master", "develop"].contains(branch)
        var steps: [String] = []
        if onDefault {
            steps.append("We are on the default branch `\(branch)`. Create a new branch with a short descriptive name for this work first.")
        }
        if hasChanges {
            steps.append("Commit the current changes with a clear, conventional commit message. Do not commit secrets, build output or unrelated files.")
        } else if ahead == 0 && !onDefault {
            steps.append("There are no local changes or unpushed commits. If there is nothing to open a pull request for, say so and stop.")
        }
        if !onDefault, let jira = JiraFollowUp.shipStep(branch: branch) { steps.append(jira) }
        let target = defaultBranch ?? "the default branch"
        switch remote?.kind ?? .github {
        case .github:
            steps.append("Push the branch to origin and set the upstream.")
            steps.append("Open a pull request with `gh pr create`. Write a concise title and a description with a short summary, the list of changes and how it was tested.")
            steps.append("Reply with the pull request URL on its own line.")
        case .gitlab:
            steps.append("Push the branch to origin and set the upstream.")
            steps.append("Open a merge request into \(target). If `glab` is installed and signed in, use `glab mr create` with a concise title and a description (short summary, list of changes, how it was tested). Otherwise create it while pushing: `git push -u origin HEAD -o merge_request.create -o merge_request.target=<target branch> -o merge_request.title=\"<title>\"`, then show the description you would add.")
            steps.append("Reply with the merge request URL on its own line.")
        case .bitbucket:
            steps.append("Push the branch to origin and set the upstream.")
            steps.append("Bitbucket has no command-line tool for pull requests here, so do not try to create it. Write a concise title and a description (short summary, list of changes, how it was tested) for me to paste.")
            steps.append("Reply with the create link \(remote.map { $0.newRequestURL(branch: branch) } ?? "Bitbucket printed after the push") on its own line.")
        case .other:
            steps.append("Push the branch to origin and set the upstream.")
            steps.append("If the push output contains a link to create a pull request, reply with it on its own line, together with a concise title and description. Otherwise just confirm the push.")
        }
        let noun = remote?.noun ?? "pull request"
        return "Open a \(noun) for this work:\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static func commitPrompt(pr: Int) -> String {
        "Commit the current changes with a clear message and push them so pull request #\(pr) is updated. Reply with a one-line summary."
    }

    static let createCommands = ["gh pr create", "glab mr create", "merge_request.create"]

    static func pullRequestURL(in text: String) -> String? {
        let patterns = [
            #"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull/\d+"#,
            #"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-/]+/-/merge_requests/\d+"#,
            #"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull-requests/\d+"#
        ]
        let hits = patterns.compactMap { p in text.range(of: p, options: .regularExpression) }
        guard let first = hits.min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        return String(text[first])
    }

    struct CreatedRequest: Equatable {
        let repo: String
        let number: String
        let mergeRequest: Bool

        var title: String { mergeRequest ? "Merge request !\(number) is open" : "Pull request #\(number) is open" }
    }

    static func describe(_ url: String) -> CreatedRequest {
        let number = url.split(separator: "/").last.map(String.init) ?? ""
        guard let u = URL(string: url) else { return CreatedRequest(repo: "", number: number, mergeRequest: false) }
        let parts = u.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "-"), parts.dropFirst(i).first == "-", parts.count > i + 1, parts[i + 1] == "merge_requests" {
            return CreatedRequest(repo: parts[..<i].joined(separator: "/"), number: number, mergeRequest: true)
        }
        return CreatedRequest(repo: parts.count >= 2 ? "\(parts[0])/\(parts[1])" : "", number: number, mergeRequest: false)
    }
}

struct CreatedPRCard: View {
    let url: String
    @Environment(AppModel.self) private var app

    private var info: AgentShip.CreatedRequest { AgentShip.describe(url) }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "arrow.triangle.pull", color: .syViolet, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.syBody.weight(.semibold)).foregroundStyle(Color.syText)
                Text(info.repo).font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Spacer(minLength: 8)
            Button("Copy Link") { copyToPasteboard(url) }.controlSize(.small)
            Button("Open in PullYard") {
                if let r = GitHubURL.parse(url, allowShort: false) {
                    app.section = .prs(.mine)
                    app.open(r)
                } else if let u = URL(string: url) {
                    LinkBrowser.open(u)
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.syAgentAccent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syViolet.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syViolet.opacity(0.25)))
    }
}

struct ForgeShipPanel: View {
    let tab: ClaudeTab
    let remote: GitRemote
    @Environment(AppModel.self) private var app

    private var service: String {
        switch remote.kind {
        case .gitlab: return "GitLab"
        case .bitbucket: return "Bitbucket"
        default: return remote.host
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull").font(.syTitle2).foregroundStyle(Color.syDim)
            Text("\(service) · \(remote.path)").font(.syCallout.weight(.medium)).foregroundStyle(Color.syText)
            if let branch = tab.git.branch, branch != "HEAD" {
                Text("Branch \(branch)").font(.syCaption).foregroundStyle(Color.syMuted)
                HStack(spacing: 8) {
                    Button(remote.kind == .gitlab ? "Open MR with Agent" : "Open PR with Agent") {
                        app.claude.send(AgentShip.openPRPrompt(branch: branch, defaultBranch: nil, hasChanges: !tab.git.changes.isEmpty, ahead: tab.git.ahead, remote: remote), to: tab)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.syAgentAccent)
                    .disabled(tab.busy)
                    Button("Create in Browser") { openInBrowser(remote.newRequestURL(branch: branch)) }
                }
                .controlSize(.small)
            }
            Button("Open \(service)") { openInBrowser(remote.webURL) }
                .buttonStyle(.link)
                .font(.syCaption)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
