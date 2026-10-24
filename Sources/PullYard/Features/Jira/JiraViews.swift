import SwiftUI

struct JiraConnectForm: View {
    var compact = false
    @State private var account = JiraAccount.shared
    @State private var site = JiraAccount.shared.site
    @State private var email = JiraAccount.shared.email
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if account.isConfigured {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.syGreen)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName ?? "Connected").foregroundStyle(Color.syText)
                        Text(account.baseURL?.host ?? "").font(.syCaption).foregroundStyle(Color.syMuted)
                    }
                    Spacer()
                    Button("Disconnect") { account.disconnect() }
                }
            } else {
                Text("Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in the Keychain.")
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                TextField("Jira address — acme.atlassian.net", text: $site).textFieldStyle(.roundedBorder)
                TextField("Atlassian account email (empty for a Data Center token)", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
                HStack {
                    SecureField("API token", text: $token).textFieldStyle(.roundedBorder).onSubmit(connect)
                    Button(action: connect) {
                        if busy { WakeLoader() } else { Text("Connect") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || site.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("Create an API token at id.atlassian.com") { openInBrowser("https://id.atlassian.com/manage-profile/security/api-tokens") }
                    .buttonStyle(.link)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).textSelection(.enabled)
                }
            }
        }
    }

    private func connect() {
        busy = true
        error = nil
        Task {
            do {
                try await account.connect(site: site, email: email, token: token)
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct JiraTab: View {
    let pr: PullRequestDetail
    @State private var account = JiraAccount.shared
    @State private var issues: [JiraIssue] = []
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var manualKey = ""

    static func keys(for pr: PullRequestDetail) -> [String] {
        var out: [String] = []
        for k in JiraAccount.shared.linkedKeys(for: pr.url) + JiraKeys.detected(title: pr.title, branch: pr.headRefName, body: pr.body) where !out.contains(k) { out.append(k) }
        return out
    }

    var body: some View {
        let keys = Self.keys(for: pr)
        let linked = account.linkedKeys(for: pr.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !account.isConfigured {
                    card { JiraConnectForm() }
                } else if keys.isEmpty {
                    card {
                        Label("No Jira ticket found", systemImage: "ticket").font(.syHeadline)
                        Text("PullYard looks for keys like ABC-123 in the title, branch and description. Link one by hand:")
                            .font(.syCallout).foregroundStyle(Color.syMuted)
                        linkField
                    }
                } else {
                    ForEach(keys, id: \.self) { key in
                        if let issue = issues.first(where: { $0.key == key }) {
                            JiraIssueCard(issue: issue, manual: linked.contains(key), onUnlink: { unlink(key) }) { updated in
                                account.remember(updated)
                                if let i = issues.firstIndex(where: { $0.key == updated.key }) { issues[i] = updated }
                            }
                        } else if let error = errors[key] {
                            card {
                                Label("\(key): \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.syAmber)
                                if linked.contains(key) { Button("Unlink") { unlink(key) }.controlSize(.small) }
                            }
                        } else {
                            card {
                                HStack(spacing: 10) { WakeLoader(); Text(key).foregroundStyle(Color.syMuted) }
                            }
                        }
                    }
                    HStack {
                        linkField
                        Spacer()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(account.isConfigured)|\(keys.joined(separator: ","))") { await load(keys) }
    }

    private var linkField: some View {
        HStack {
            TextField("ABC-123", text: $manualKey).textFieldStyle(.roundedBorder).frame(width: 140).onSubmit(link)
            Button("Link ticket", action: link).disabled(manualKey.trimmingCharacters(in: .whitespaces).count < 3)
        }
        .controlSize(.small)
    }

    private func link() {
        guard let key = JiraKeys.extract([manualKey.uppercased()]).first else { return }
        var linked = account.linkedKeys(for: pr.url)
        if !linked.contains(key) { linked.append(key) }
        account.setLinkedKeys(linked, for: pr.url)
        manualKey = ""
    }

    private func unlink(_ key: String) {
        account.setLinkedKeys(account.linkedKeys(for: pr.url).filter { $0 != key }, for: pr.url)
        issues.removeAll { $0.key == key }
    }

    private func load(_ keys: [String]) async {
        guard let client = account.client() else { return }
        for key in keys where !issues.contains(where: { $0.key == key }) {
            if let hit = account.cachedIssue(key) { issues.append(hit) }
        }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, Result<JiraIssue, Error>).self) { group in
            for key in keys where !issues.contains(where: { $0.key == key }) && errors[key] == nil {
                group.addTask {
                    do { return (key, .success(try await client.issue(key))) } catch { return (key, .failure(error)) }
                }
            }
            for await (key, result) in group {
                switch result {
                case .success(let issue): issues.append(issue); errors[key] = nil; account.remember(issue)
                case .failure(let e): errors[key] = e.localizedDescription
                }
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 12)
    }
}

struct JiraIssueCard: View {
    let issue: JiraIssue
    var manual = false
    var onUnlink: () -> Void = {}
    let onChange: (JiraIssue) -> Void
    @State private var transitions: [JiraTransition] = []
    @State private var loadingTransitions = false
    @State private var moving = false
    @State private var error: String?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: typeIcon).foregroundStyle(typeColor)
                Button(issue.key) { openInBrowser(issue.url) }
                    .buttonStyle(.link)
                    .font(.syCallout.weight(.semibold).monospaced())
                if let type = issue.type { Text(type).font(.syCaption).foregroundStyle(Color.syMuted) }
                Spacer()
                statusMenu
            }
            Text(issue.summary).font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText).textSelection(.enabled)
            HStack(spacing: 16) {
                if let a = issue.assignee {
                    HStack(spacing: 6) {
                        Avatar(url: issue.assigneeAvatar, size: 18)
                        Text(a)
                    }
                } else {
                    Label("Unassigned", systemImage: "person.crop.circle.badge.questionmark")
                }
                if let p = issue.priority { Label(p, systemImage: "flag") }
                if let r = issue.reporter { Label("Reported by \(r)", systemImage: "megaphone") }
                if let u = issue.updated { Text("Updated " + Fmt.rel(u)) }
            }
            .font(.syCaption)
            .foregroundStyle(Color.syMuted)
            if !issue.description.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.description)
                        .font(.syCallout)
                        .foregroundStyle(Color.syText.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 8)
                    if issue.description.count > 500 {
                        Button(expanded ? "Show less" : "Show more") { withAnimation(Motion.smooth) { expanded.toggle() } }
                            .buttonStyle(.link)
                            .font(.syCaption)
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed)
            }
            HStack {
                Button("Open in Jira") { openInBrowser(issue.url) }
                if manual { Button("Unlink", action: onUnlink) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
        .onChange(of: issue.status) { transitions = [] }
    }

    private var statusMenu: some View {
        Menu {
            if transitions.isEmpty {
                Text(loadingTransitions ? "Loading…" : "No transitions available")
            }
            ForEach(transitions) { t in
                Button {
                    move(t)
                } label: {
                    Text(t.name == t.to ? t.name : "\(t.name) → \(t.to)")
                }
            }
        } label: {
            HStack(spacing: 5) {
                if moving { WakeLoader() }
                Text(issue.status.uppercased()).font(.syCaption.weight(.bold))
                Image(systemName: "chevron.down").font(.syCaption2.weight(.semibold))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(statusColor.opacity(0.14)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in
            guard inside, transitions.isEmpty, !loadingTransitions else { return }
            Task { await loadTransitions() }
        }
        .disabled(moving)
        .help("Change status")
    }

    private var statusColor: Color { Self.color(category: issue.statusCategory) }

    static func color(category: String) -> Color {
        switch category {
        case "done": return .syGreen
        case "indeterminate": return .sySky
        default: return .syMuted
        }
    }

    private var typeIcon: String {
        switch issue.type?.lowercased() ?? "" {
        case let t where t.contains("bug"): return "ladybug.fill"
        case let t where t.contains("epic"): return "bolt.fill"
        case let t where t.contains("story"): return "bookmark.fill"
        case let t where t.contains("sub"): return "square.split.2x1.fill"
        default: return "checkmark.square.fill"
        }
    }

    private var typeColor: Color {
        switch typeIcon {
        case "ladybug.fill": return .syRed
        case "bolt.fill": return .syViolet
        case "bookmark.fill": return .syGreen
        default: return .sySky
        }
    }

    private func loadTransitions() async {
        guard let client = JiraAccount.shared.client() else { return }
        loadingTransitions = true
        transitions = (try? await client.transitions(issue.key)) ?? []
        loadingTransitions = false
    }

    private func move(_ t: JiraTransition) {
        guard let client = JiraAccount.shared.client() else { return }
        moving = true
        error = nil
        Task {
            do {
                try await client.transition(issue.key, to: t.id)
                onChange(try await client.issue(issue.key))
            } catch {
                self.error = error.localizedDescription
            }
            moving = false
        }
    }
}
