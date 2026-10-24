import SwiftUI

enum AgentShip {
    static func openPRPrompt(branch: String, defaultBranch: String?, hasChanges: Bool, ahead: Int) -> String {
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
        steps.append("Push the branch to origin and set the upstream.")
        steps.append("Open a pull request with `gh pr create`. Write a concise title and a description with a short summary, the list of changes and how it was tested.")
        steps.append("Reply with the pull request URL on its own line.")
        return "Open a pull request for this work:\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    static func commitPrompt(pr: Int) -> String {
        "Commit the current changes with a clear message and push them so pull request #\(pr) is updated. Reply with a one-line summary."
    }

    static func pullRequestURL(in text: String) -> String? {
        guard let r = text.range(of: #"https://[A-Za-z0-9.\-]+/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+/pull/\d+"#, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}

struct CreatedPRCard: View {
    let url: String
    @Environment(AppModel.self) private var app

    private var number: String { url.split(separator: "/").last.map(String.init) ?? "" }
    private var repo: String {
        let parts = url.split(separator: "/")
        return parts.count >= 5 ? "\(parts[2])/\(parts[3])" : ""
    }

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "arrow.triangle.pull", color: .syViolet, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pull request #\(number) is open").font(.syBody.weight(.semibold)).foregroundStyle(Color.syText)
                Text(repo).font(.syCaption).foregroundStyle(Color.syMuted)
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
