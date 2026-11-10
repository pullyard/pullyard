import SwiftUI

enum JiraFollowUp {
    static let dismissedKey = "jira.mergeFollowUpDismissed"

    static func open(_ issues: [JiraIssue]) -> [JiraIssue] {
        issues.filter { $0.statusCategory.lowercased() != "done" }
    }

    static func doneTransition(_ transitions: [JiraTransition]) -> JiraTransition? {
        let done = transitions.filter { $0.toCategory.lowercased() == "done" }
        let preferred = ["done", "closed", "resolved", "complete", "completed"]
        return done.first { preferred.contains($0.to.lowercased()) } ?? done.first
    }

    static func isDismissed(_ prURL: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).contains(prURL)
    }

    static func dismiss(_ prURL: String) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        guard !list.contains(prURL) else { return }
        list.append(prURL)
        UserDefaults.standard.set(Array(list.suffix(500)), forKey: dismissedKey)
    }

    static func shipStep(branch: String) -> String? {
        let keys = JiraKeys.extract(branch: branch)
        guard !keys.isEmpty else { return nil }
        let list = keys.joined(separator: ", ")
        return "The branch refers to Jira issue\(keys.count == 1 ? "" : "s") \(list). Start the title with \(keys[0]) and mention \(list) in the description."
    }
}

@Observable
@MainActor
final class JiraFollowUpLoader {
    private(set) var issues: [JiraIssue] = []
    private(set) var transitions: [String: JiraTransition] = [:]
    var dismissed = false

    func load(_ pr: PullRequestDetail) async {
        dismissed = JiraFollowUp.isDismissed(pr.url)
        guard pr.merged, !dismissed, JiraAccount.shared.isConfigured, let client = JiraAccount.shared.client() else {
            issues = []
            transitions = [:]
            return
        }
        var found: [JiraIssue] = []
        for key in JiraTab.keys(for: pr).prefix(5) {
            if let hit = JiraAccount.shared.cachedIssue(key) {
                found.append(hit)
            } else if let fresh = try? await client.issue(key) {
                JiraAccount.shared.remember(fresh)
                found.append(fresh)
            }
        }
        var moves: [String: JiraTransition] = [:]
        for issue in JiraFollowUp.open(found) {
            if let t = JiraFollowUp.doneTransition((try? await client.transitions(issue.key)) ?? []) { moves[issue.key] = t }
        }
        issues = found
        transitions = moves
    }

    func replace(_ issue: JiraIssue) {
        issues = issues.map { $0.key == issue.key ? issue : $0 }
    }
}

struct JiraMergeFollowUp: View {
    let pr: PullRequestDetail
    let loader: JiraFollowUpLoader
    @State private var working: String?
    @State private var error: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        let pending = JiraFollowUp.open(loader.issues)
        if pr.merged, !loader.dismissed, !pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pending) { issue in
                    HStack(spacing: 8) {
                        Image(systemName: "ticket").foregroundStyle(Color.sySky)
                        Text(issue.key).font(.syCallout.monospaced().weight(.semibold))
                        Text("is still \(issue.status)").font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(1)
                        Spacer()
                        if let t = loader.transitions[issue.key] {
                            Button(working == issue.key ? "Moving…" : "Move to \(t.to)") { move(issue, t) }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .tint(Color.syGreenFill)
                                .disabled(working != nil)
                        }
                        Button("Open in Jira") { if let u = URL(string: issue.url) { LinkBrowser.open(u) } }
                            .controlSize(.small)
                    }
                }
                HStack {
                    if let error { Text(error).font(.syCaption).foregroundStyle(Color.syRed) }
                    Spacer()
                    Button("Not now") {
                        JiraFollowUp.dismiss(pr.url)
                        loader.dismissed = true
                    }
                    .buttonStyle(.link)
                    .font(.syCaption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySky.opacity(0.07)))
        }
    }

    private func move(_ issue: JiraIssue, _ t: JiraTransition) {
        guard let client = JiraAccount.shared.client() else { return }
        working = issue.key
        error = nil
        Task {
            do {
                try await client.transition(issue.key, to: t.id)
                if let fresh = try? await client.issue(issue.key) {
                    JiraAccount.shared.remember(fresh)
                    loader.replace(fresh)
                }
                app.showToast("\(issue.key) moved to \(t.to)")
            } catch {
                self.error = error.localizedDescription
            }
            working = nil
        }
    }
}
