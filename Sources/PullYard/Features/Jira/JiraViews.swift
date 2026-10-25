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
                site = account.site
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
    @State private var linking = false
    @State private var open: Set<String> = []
    @State private var reload = 0

    static func keys(for pr: PullRequestDetail) -> [String] {
        var out: [String] = []
        for k in JiraAccount.shared.linkedKeys(for: pr.url) + JiraKeys.detected(title: pr.title, branch: pr.headRefName, body: pr.body) where !out.contains(k) { out.append(k) }
        return out
    }

    var body: some View {
        let keys = Self.keys(for: pr)
        let linked = account.linkedKeys(for: pr.url)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !account.isConfigured {
                    JiraPanel { JiraConnectForm() }
                } else {
                    header(count: keys.count)
                    if linking { linkField.transition(.reveal) }
                    if keys.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                            entry(key, primary: index == 0, manual: linked.contains(key))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.smooth, value: linking)
            .animation(Motion.smooth, value: open)
        }
        .task(id: "\(account.isConfigured)|\(keys.joined(separator: ","))|\(reload)") { await load(keys) }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: "ticket", color: .sySky, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 linked ticket" : "\(count) linked tickets").font(.syHeadline).foregroundStyle(Color.syText)
                Text(account.baseURL?.host ?? "").font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Spacer()
            if loading { WakeLoader() }
            Button {
                withAnimation(Motion.smooth) { linking.toggle() }
            } label: {
                Label("Link ticket", systemImage: linking ? "xmark" : "plus")
            }
            .controlSize(.small)
            Button {
                issues = []
                errors = [:]
                account.clearCache()
                reload += 1
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Reload from Jira")
        }
    }

    @ViewBuilder
    private func entry(_ key: String, primary: Bool, manual: Bool) -> some View {
        if let issue = issues.first(where: { $0.key == key }) {
            if primary || open.contains(key) {
                JiraIssueCard(issue: issue, manual: manual, onUnlink: { unlink(key) }, onCollapse: primary ? nil : { open.remove(key) }) { updated in
                    account.remember(updated)
                    if let i = issues.firstIndex(where: { $0.key == updated.key }) { issues[i] = updated }
                }
            } else {
                JiraIssueRow(issue: issue) { open.insert(key) }
            }
        } else if let error = errors[key] {
            JiraPanel {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syAmber)
                    Text(key).font(.syCallout.weight(.semibold).monospaced())
                    Text(error).font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(2)
                    Spacer()
                    if manual { Button("Unlink") { unlink(key) }.controlSize(.small) }
                }
            }
        } else {
            JiraPanel {
                HStack(spacing: 10) {
                    WakeLoader()
                    Text(key).font(.syCallout.monospaced()).foregroundStyle(Color.syMuted)
                    Spacer()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "ticket").font(.system(size: 30)).foregroundStyle(Color.syDim)
            Text("No Jira ticket on this pull request").font(.syHeadline).foregroundStyle(Color.syText)
            Text("PullYard looks for keys like ABC-123 in the title, branch name and description.")
                .font(.syCallout).foregroundStyle(Color.syMuted).multilineTextAlignment(.center)
            if !linking {
                Button("Link a ticket") { withAnimation(Motion.smooth) { linking = true } }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(Color.syMuted)
            TextField("Ticket key, e.g. ABC-123", text: $manualKey)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit(link)
            Button("Link", action: link)
                .buttonStyle(.borderedProminent)
                .disabled(JiraKeys.extract([manualKey.uppercased()]).isEmpty)
            Text("Saved for this pull request on this Mac.").font(.syCaption).foregroundStyle(Color.syDim)
            Spacer()
        }
        .controlSize(.small)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syText.opacity(0.04)))
    }

    private func link() {
        guard let key = JiraKeys.extract([manualKey.uppercased()]).first else { return }
        var linked = account.linkedKeys(for: pr.url)
        if !linked.contains(key) { linked.insert(key, at: 0) }
        account.setLinkedKeys(linked, for: pr.url)
        manualKey = ""
        linking = false
    }

    private func unlink(_ key: String) {
        account.setLinkedKeys(account.linkedKeys(for: pr.url).filter { $0 != key }, for: pr.url)
        issues.removeAll { $0.key == key }
        open.remove(key)
    }

    private func load(_ keys: [String]) async {
        guard let client = account.client() else { return }
        for key in keys where !issues.contains(where: { $0.key == key }) {
            if let hit = account.cachedIssue(key) { issues.append(hit) }
        }
        let missing = keys.filter { key in !issues.contains(where: { $0.key == key }) && errors[key] == nil }
        guard !missing.isEmpty else { return }
        loading = true
        defer { loading = false }
        await withTaskGroup(of: (String, Result<JiraIssue, Error>).self) { group in
            for key in missing {
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
}

struct JiraPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.syRaised))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.syLine))
    }
}

enum JiraStyle {
    static func statusColor(_ category: String) -> Color {
        switch category {
        case "done": return .syGreen
        case "indeterminate": return .sySky
        default: return .syMuted
        }
    }

    static func typeIcon(_ type: String?) -> String {
        let t = type?.lowercased() ?? ""
        if t.contains("bug") { return "ladybug.fill" }
        if t.contains("epic") { return "bolt.fill" }
        if t.contains("story") { return "bookmark.fill" }
        if t.contains("sub") { return "square.split.2x1.fill" }
        return "checkmark.square.fill"
    }

    static func typeColor(_ type: String?) -> Color {
        let t = type?.lowercased() ?? ""
        if t.contains("bug") { return .syRed }
        if t.contains("epic") { return .syViolet }
        if t.contains("story") { return .syGreen }
        return .sySky
    }

    static func priorityColor(_ priority: String?) -> Color {
        switch priority?.lowercased() ?? "" {
        case "highest", "blocker", "critical": return .syRed
        case "high", "major": return .syCoral
        case "medium": return .syAmber
        default: return .syMuted
        }
    }
}

struct JiraStatusPill: View {
    let status: String
    let category: String
    var chevron = false
    var busy = false

    var body: some View {
        let color = JiraStyle.statusColor(category)
        HStack(spacing: 5) {
            if busy { WakeLoader() } else { Circle().fill(color).frame(width: 6, height: 6) }
            Text(status.uppercased()).font(.syCaption.weight(.bold))
            if chevron { Image(systemName: "chevron.down").font(.syCaption2.weight(.semibold)) }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

struct JiraIssueRow: View {
    let issue: JiraIssue
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: JiraStyle.typeIcon(issue.type)).foregroundStyle(JiraStyle.typeColor(issue.type))
                Text(issue.key).font(.syCallout.weight(.semibold).monospaced()).foregroundStyle(Color.syText)
                Text(issue.summary).font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(1)
                Spacer(minLength: 8)
                JiraStatusPill(status: issue.status, category: issue.statusCategory)
                Image(systemName: "chevron.right").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.syText.opacity(hover ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show details")
    }
}

struct JiraIssueCard: View {
    let issue: JiraIssue
    var manual = false
    var onUnlink: () -> Void = {}
    var onCollapse: (() -> Void)?
    let onChange: (JiraIssue) -> Void
    @State private var transitions: [JiraTransition] = []
    @State private var loadingTransitions = false
    @State private var moving = false
    @State private var error: String?
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let parent = issue.parentKey {
                Button {
                    if let base = JiraAccount.shared.baseURL { openInBrowser(base.absoluteString + "/browse/" + parent) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.left.up").font(.syCaption2)
                        Text(parent).font(.syCaption.weight(.semibold).monospaced())
                        if let summary = issue.parentSummary { Text(summary).font(.syCaption).lineLimit(1) }
                    }
                    .foregroundStyle(Color.syMuted)
                }
                .buttonStyle(.plain)
                .help("Parent ticket — open in Jira")
            }
            HStack(alignment: .center, spacing: 10) {
                IconTile(systemImage: JiraStyle.typeIcon(issue.type), color: JiraStyle.typeColor(issue.type), size: 24)
                Text(issue.key).font(.syCallout.weight(.semibold).monospaced()).foregroundStyle(Color.syText)
                if let type = issue.type { Text(type).font(.syCaption).foregroundStyle(Color.syMuted) }
                Spacer()
                statusMenu
                if let onCollapse {
                    Button(action: onCollapse) { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .help("Collapse")
                }
            }
            Text(issue.summary).font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText).textSelection(.enabled)
            meta
            if !issue.description.isEmpty { description }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed)
            }
            Divider()
            HStack(spacing: 8) {
                Button { openInBrowser(issue.url) } label: { Label("Open in Jira", systemImage: "arrow.up.right.square") }
                Button {
                    copyToPasteboard(issue.url)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link") }
                Spacer()
                if manual {
                    Button(role: .destructive, action: onUnlink) { Label("Unlink", systemImage: "link.badge.minus") }
                        .buttonStyle(.borderless)
                }
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.syLine))
        .onChange(of: issue.status) { transitions = [] }
    }

    private var meta: some View {
        HStack(spacing: 8) {
            metaChip {
                if let a = issue.assignee {
                    Avatar(url: issue.assigneeAvatar, size: 16)
                    Text(a)
                } else {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                    Text("Unassigned")
                }
            }
            .help("Assignee")
            if let p = issue.priority {
                metaChip {
                    Image(systemName: "flag.fill").foregroundStyle(JiraStyle.priorityColor(p))
                    Text(p)
                }
                .help("Priority")
            }
            if let r = issue.reporter, r != issue.assignee {
                metaChip {
                    Image(systemName: "megaphone")
                    Text(r)
                }
                .help("Reporter")
            }
            if let u = issue.updated {
                metaChip {
                    Image(systemName: "clock")
                    Text(Fmt.rel(u))
                }
                .help("Updated")
            }
        }
        .font(.syCaption)
        .foregroundStyle(Color.syMuted)
    }

    private func metaChip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 5, content: content)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.syText.opacity(0.05)))
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Description").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
            Text(issue.description)
                .font(.syCallout)
                .foregroundStyle(Color.syText.opacity(0.9))
                .textSelection(.enabled)
                .lineLimit(expanded ? nil : 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            if issue.description.count > 320 || issue.description.split(separator: "\n").count > 6 {
                Button(expanded ? "Show less" : "Show more") { withAnimation(Motion.smooth) { expanded.toggle() } }
                    .buttonStyle(.link)
                    .font(.syCaption)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySunken))
    }

    private var statusMenu: some View {
        Menu {
            if transitions.isEmpty {
                Text(loadingTransitions ? "Loading…" : "No transitions available")
            } else {
                Section("Move to") {
                    ForEach(transitions) { t in
                        Button { move(t) } label: { Text(t.name == t.to ? t.name : "\(t.name) → \(t.to)") }
                    }
                }
            }
        } label: {
            JiraStatusPill(status: issue.status, category: issue.statusCategory, chevron: true, busy: moving)
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
