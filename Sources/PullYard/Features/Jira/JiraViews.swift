import SwiftUI

struct JiraConnectForm: View {
    @State private var store = JiraConnections.shared
    @State private var editing: JiraConnection?
    @State private var adding = false
    @State private var removing: JiraConnection?
    @State private var refreshing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.connections.isEmpty && !adding {
                JiraConnectionEditor(existing: nil) { adding = false }
            } else {
                ForEach(store.connections) { c in
                    if editing?.id == c.id {
                        JiraConnectionEditor(existing: c) { editing = nil }
                    } else {
                        row(c)
                    }
                }
                if adding {
                    JiraConnectionEditor(existing: nil) { adding = false }
                } else {
                    Button { adding = true } label: { Label("Add Jira connection", systemImage: "plus") }
                        .controlSize(.small)
                }
                if store.hasSeveral || !store.orgOverrides.isEmpty || !store.repoOverrides.isEmpty {
                    JiraRoutingRules()
                }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this connection")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { store.remove(id) }
                removing = nil
            }
        } message: {
            Text("Its API token is deleted from the Keychain. Rules that point to it are removed too.")
        }
    }

    private func row(_ c: JiraConnection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: store.token(for: c.id) == nil ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(store.token(for: c.id) == nil ? Color.syAmber : Color.syGreen)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(c.name).foregroundStyle(Color.syText)
                    if let me = c.displayName { Text(me).font(.syCaption).foregroundStyle(Color.syMuted) }
                }
                Text(subtitle(c)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                    .help(c.projectKeys.joined(separator: ", "))
            }
            Spacer()
            if refreshing.contains(c.id) { WakeLoader() }
            Menu {
                Button("Edit…") { editing = c }
                Button("Reconnect with a new token…") { editing = c }
                Button("Refresh projects") { refresh(c.id) }
                Divider()
                Button("Remove…", role: .destructive) { removing = c }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(c.name)")
        }
    }

    private func subtitle(_ c: JiraConnection) -> String {
        var parts = [c.host]
        if !c.projectKeys.isEmpty {
            let shown = c.projectKeys.prefix(5).joined(separator: ", ")
            parts.append(c.projectKeys.count > 5 ? "\(shown) +\(c.projectKeys.count - 5)" : shown)
        }
        return parts.joined(separator: " · ")
    }

    private func refresh(_ id: String) {
        refreshing.insert(id)
        Task {
            await store.refreshProjects(id)
            refreshing.remove(id)
        }
    }
}

struct JiraConnectionEditor: View {
    let existing: JiraConnection?
    let done: () -> Void
    @State private var name = ""
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if existing == nil {
                Text(JiraConnections.shared.isConfigured ? "Add another Jira site. PullYard picks the right one for each ticket by its project key." : "Connect Jira to see the ticket for a pull request and move it between statuses. Your API token stays in the Keychain.")
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
            }
            TextField("Name — e.g. Work A", text: $name).textFieldStyle(.roundedBorder)
            TextField("Jira address — acme.atlassian.net", text: $site).textFieldStyle(.roundedBorder)
            TextField("Atlassian account email (empty for a Data Center token)", text: $email).textFieldStyle(.roundedBorder).textContentType(.username)
            HStack {
                SecureField(existing == nil ? "API token" : "New API token (leave empty to keep the current one)", text: $token).textFieldStyle(.roundedBorder).onSubmit(save)
                Button(action: save) {
                    if busy { WakeLoader() } else { Text(existing == nil ? "Connect" : "Save") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || site.trimmingCharacters(in: .whitespaces).isEmpty || (existing == nil && token.trimmingCharacters(in: .whitespaces).isEmpty))
                if existing != nil || JiraConnections.shared.isConfigured {
                    Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                }
            }
            Button("Create an API token at id.atlassian.com") { openInBrowser("https://id.atlassian.com/manage-profile/security/api-tokens") }
                .buttonStyle(.link)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).textSelection(.enabled)
            }
        }
        .padding(existing == nil && !JiraConnections.shared.isConfigured ? 0 : 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syText.opacity(existing == nil && !JiraConnections.shared.isConfigured ? 0 : 0.04)))
        .onAppear {
            guard let existing else { return }
            name = existing.name
            site = existing.site
            email = existing.email
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            do {
                if let existing {
                    try await JiraConnections.shared.update(existing.id, name: name, site: site, email: email, token: token)
                } else {
                    try await JiraConnections.shared.add(name: name, site: site, email: email, token: token)
                }
                token = ""
                done()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

struct JiraRoutingRules: View {
    @State private var store = JiraConnections.shared
    @State private var org = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
            Text("Tickets go to the site that owns their project key. A rule wins over that: a repository rule first, then an organization rule.")
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
            ForEach(rules, id: \.key) { rule in
                HStack(spacing: 8) {
                    Image(systemName: rule.isRepo ? "book.closed" : "building.2").foregroundStyle(Color.syMuted).frame(width: 16)
                    Text(rule.isRepo ? rule.key : rule.key + "/*").font(.syCallout.monospaced())
                    Image(systemName: "arrow.right").font(.syCaption2).foregroundStyle(Color.syDim)
                    Text(store.connection(rule.id)?.name ?? "—").font(.syCallout)
                    Spacer()
                    Button {
                        if rule.isRepo {
                            if let repo = RepoRef(full: rule.key) { store.setRepoOverride(nil, for: repo) }
                        } else {
                            store.setOrgOverride(nil, for: rule.key)
                        }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.syMuted)
                    .help("Remove this rule")
                    .accessibilityLabel("Remove rule for \(rule.key)")
                }
            }
            HStack(spacing: 8) {
                TextField("GitHub organization", text: $org).textFieldStyle(.roundedBorder).frame(maxWidth: 200).onSubmit(addOrg)
                Picker("Jira", selection: $target) {
                    ForEach(store.connections) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add rule", action: addOrg)
                    .disabled(org.trimmingCharacters(in: .whitespaces).isEmpty || store.connection(target) == nil)
            }
            .controlSize(.small)
        }
        .padding(.top, 6)
        .onAppear { if store.connection(target) == nil { target = store.connections.first?.id ?? "" } }
    }

    private var rules: [(key: String, id: String, isRepo: Bool)] {
        store.repoOverrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value, true) }
            + store.orgOverrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value, false) }
    }

    private func addOrg() {
        let name = org.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@/*"))
        guard !name.isEmpty, store.connection(target) != nil else { return }
        store.setOrgOverride(target, for: name)
        org = ""
    }
}

struct JiraRepoChip: View {
    let repo: RepoRef
    @State private var store = JiraConnections.shared

    var body: some View {
        if store.isConfigured {
            let current = store.override(for: repo)
            let id = store.connectionForRepo(repo)
            Menu {
                Section("Jira for \(repo.full)") {
                    Button { store.setRepoOverride(nil, for: repo) } label: {
                        if current.repo == nil { Label(automaticTitle(org: current.org), systemImage: "checkmark") } else { Text(automaticTitle(org: current.org)) }
                    }
                    ForEach(store.connections) { c in
                        Button { store.setRepoOverride(c.id, for: repo) } label: {
                            if current.repo == c.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                        }
                    }
                }
                if store.hasSeveral {
                    Section("All of \(repo.owner)") {
                        Button { store.setOrgOverride(nil, for: repo.owner) } label: {
                            if current.org == nil { Label("By project key", systemImage: "checkmark") } else { Text("By project key") }
                        }
                        ForEach(store.connections) { c in
                            Button { store.setOrgOverride(c.id, for: repo.owner) } label: {
                                if current.org == c.id { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "ticket")
                    Text(store.connection(id)?.name ?? "Jira: by key")
                }
                .font(.syCaption.weight(.medium))
                .foregroundStyle(Color.sySky)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.sySky.opacity(0.12)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Which Jira this repository's tickets come from")
        }
    }

    private func automaticTitle(org: String?) -> String {
        if let name = store.connection(org)?.name { return "Same as \(repo.owner) (\(name))" }
        return store.hasSeveral ? "Automatic — by project key" : "Automatic"
    }
}

struct JiraRepoBadge: View {
    let full: String
    @State private var store = JiraConnections.shared

    var body: some View {
        if store.hasSeveral, let repo = RepoRef(full: full), let c = store.connection(store.connectionForRepo(repo)) {
            Label(c.name, systemImage: "ticket")
                .font(.syCaption2)
                .foregroundStyle(Color.sySky)
                .lineLimit(1)
                .help("Jira tickets come from \(c.name)")
        }
    }
}

struct JiraTab: View {
    let pr: PullRequestDetail
    var repo: RepoRef?
    @State private var account = JiraConnections.shared
    @State private var issues: [JiraIssue] = []
    @State private var errors: [String: String] = [:]
    @State private var loading = false
    @State private var manualKey = ""
    @State private var linking = false
    @State private var open: Set<String> = []
    @State private var reload = 0
    @State private var lastUpdated: Date?
    @Environment(AppModel.self) private var app

    static func keys(for pr: PullRequestDetail) -> [String] {
        let linked = JiraConnections.shared.linkedKeys(for: pr.url)
        let hidden = Set(JiraConnections.shared.hiddenKeys(for: pr.url))
        var out: [String] = []
        for k in linked + JiraKeys.detected(title: pr.title, branch: pr.headRefName, body: pr.body) where !out.contains(k) && (linked.contains(k) || !hidden.contains(k)) { out.append(k) }
        return out
    }

    var body: some View {
        let keys = Self.keys(for: pr)
        let linked = account.linkedKeys(for: pr.url)
        let hiddenCount = account.hiddenKeys(for: pr.url).count
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
                    if hiddenCount > 0 {
                        Button(hiddenCount == 1 ? "Show 1 hidden ticket" : "Show \(hiddenCount) hidden tickets") {
                            account.setHiddenKeys([], for: pr.url)
                            reload += 1
                        }
                        .buttonStyle(.link)
                        .font(.syCaption)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(Motion.smooth, value: linking)
            .animation(Motion.smooth, value: open)
        }
        .task(id: "\(account.connections.map(\.id).joined())|\(keys.joined(separator: ","))|\(reload)") { await load(keys) }
        .onChange(of: app.refreshTick) {
            Task {
                await account.refreshAllProjects(olderThan: 600)
                await load(Self.keys(for: pr), force: true)
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            IconTile(systemImage: "ticket", color: .sySky, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(count == 1 ? "1 linked ticket" : "\(count) linked tickets").font(.syHeadline).foregroundStyle(Color.syText)
                Text(sourceLine).font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Spacer()
            RefreshPill(updated: lastUpdated, refreshing: loading, error: errors.isEmpty ? nil : errors.values.first) {
                Task { await load(Self.keys(for: pr), force: true) }
            }
            Button {
                withAnimation(Motion.smooth) { linking.toggle() }
            } label: {
                if linking { Text("Cancel") } else { Label("Link ticket", systemImage: "plus") }
            }
            .controlSize(.small)
            .keyboardShortcut(linking ? .cancelAction : nil)
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
            .accessibilityLabel("Reload from Jira")
        }
    }

    private var sourceLine: String {
        var names: [String] = []
        for issue in issues {
            if let c = account.connection(issue.connectionID), !names.contains(c.name) { names.append(c.name) }
        }
        if names.isEmpty, let only = account.connections.first, !account.hasSeveral { return only.host }
        return names.joined(separator: " · ")
    }

    @ViewBuilder
    private func entry(_ key: String, primary: Bool, manual: Bool) -> some View {
        if let issue = issues.first(where: { $0.key == key }) {
            if primary || open.contains(key) {
                JiraIssueCard(issue: issue, editable: true, manual: manual, onUnlink: { unlink(key) }, onHide: manual ? nil : { hide(key) }, onCollapse: primary ? nil : { open.remove(key) }) { updated in
                    if let i = issues.firstIndex(where: { $0.key == updated.key }) { issues[i] = updated }
                }
            } else {
                JiraIssueRow(issue: issue, onHide: manual ? nil : { hide(key) }) { open.insert(key) }
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
                .onExitCommand { withAnimation(Motion.smooth) { linking = false } }
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
        account.setHiddenKeys(account.hiddenKeys(for: pr.url).filter { $0 != key }, for: pr.url)
        manualKey = ""
        linking = false
    }

    private func hide(_ key: String) {
        var hidden = account.hiddenKeys(for: pr.url)
        if !hidden.contains(key) { hidden.append(key) }
        account.setHiddenKeys(hidden, for: pr.url)
        issues.removeAll { $0.key == key }
        open.remove(key)
        reload += 1
    }

    private func unlink(_ key: String) {
        account.setLinkedKeys(account.linkedKeys(for: pr.url).filter { $0 != key }, for: pr.url)
        issues.removeAll { $0.key == key }
        open.remove(key)
    }

    private func load(_ keys: [String], force: Bool = false) async {
        guard account.isConfigured, !(force && loading) else { return }
        let repo = repo
        for key in keys where !issues.contains(where: { $0.key == key }) {
            if let hit = account.cachedIssue(key, repo: repo) { issues.append(hit) }
        }
        let missing = force ? keys : keys.filter { key in !issues.contains(where: { $0.key == key }) && errors[key] == nil }
        guard !missing.isEmpty else {
            if lastUpdated == nil { lastUpdated = Date() }
            return
        }
        loading = true
        defer {
            loading = false
            lastUpdated = Date()
        }
        let store = account
        await withTaskGroup(of: (String, Result<JiraIssue, Error>).self) { group in
            for key in missing {
                group.addTask {
                    do { return (key, .success(try await store.fetchIssue(key, repo: repo))) } catch { return (key, .failure(error)) }
                }
            }
            for await (key, result) in group {
                switch result {
                case .success(let issue):
                    if let i = issues.firstIndex(where: { $0.key == key }) { issues[i] = issue } else { issues.append(issue) }
                    errors[key] = nil
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
    var onHide: (() -> Void)?
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
        .contextMenu {
            Button("Open in Jira") { openInBrowser(issue.url) }
            if let onHide { Button("Hide on this pull request", action: onHide) }
        }
    }
}

struct JiraIssueCard: View {
    let issue: JiraIssue
    /// Drops the card's own background and border, for when it fills a sheet of the same colour.
    var flat = false
    /// Shows "Implement with agent" when set.
    var onImplement: (() -> Void)?
    /// Shows a close button in the header when set.
    var onClose: (() -> Void)?
    /// The full ticket is still loading: shows a shimmer where the description goes.
    var loadingDetails = false
    /// Fields and description can be changed in place (the board's ticket view).
    var editable = false
    var manual = false
    var onUnlink: () -> Void = {}
    var onHide: (() -> Void)?
    var onCollapse: (() -> Void)?
    let onChange: (JiraIssue) -> Void
    @State private var transitions: [JiraTransition] = []
    @State private var loadingTransitions = false
    @State private var moving = false
    @State private var error: String?
    @State private var expanded = false
    @State private var copied = false
    @State private var copiedKey = false
    @State private var statusOpen = false
    @State private var editingDescription = false
    @State private var hoverTransition: JiraTransition?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let parent = issue.parentKey {
                Button {
                    openInBrowser(issue.siteBase + "/browse/" + parent)
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
                if JiraConnections.shared.hasSeveral, let c = JiraConnections.shared.connection(issue.connectionID) {
                    Text(c.name)
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(Color.sySky)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.sySky.opacity(0.12)))
                        .help(c.host)
                }
                Spacer()
                statusMenu
                if let onCollapse {
                    Button(action: onCollapse) { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                        .help("Collapse")
                        .accessibilityLabel("Collapse")
                }
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.syCaption.weight(.bold))
                            .foregroundStyle(Color.syMuted)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.syText.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                    .accessibilityLabel("Close")
                }
            }
            Text(issue.summary).font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText).textSelection(.enabled)
            if editable { JiraIssueFields(issue: issue, onChange: onChange) } else { meta }
            if editingDescription {
                JiraDescriptionEditor(issue: issue) {
                    withAnimation(Motion.fade) { editingDescription = false }
                } onChange: { onChange($0) }
            } else if !issue.description.isEmpty {
                description
            } else if loadingDetails {
                descriptionSkeleton
            } else if editable {
                Button { withAnimation(Motion.fade) { editingDescription = true } } label: { Label("Add description", systemImage: "text.badge.plus") }
                    .buttonStyle(JiraChipButtonStyle())
            }
            if !issue.attachments.isEmpty {
                JiraAttachmentsSection(attachments: issue.attachments, connectionID: issue.connectionID)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed)
            }
            Divider()
            HStack(spacing: 8) {
                Button { openInBrowser(issue.url) } label: { Label("Open in Jira", systemImage: "arrow.up.right.square") }
                    .buttonStyle(JiraChipButtonStyle())
                Button {
                    copyToPasteboard(issue.url)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "link") }
                    .buttonStyle(JiraChipButtonStyle(done: copied))
                Button {
                    copyToPasteboard(issue.key)
                    copiedKey = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedKey = false }
                } label: { Label(copiedKey ? "Copied" : "Copy \(issue.key)", systemImage: copiedKey ? "checkmark" : "number") }
                    .buttonStyle(JiraChipButtonStyle(done: copiedKey))
                    .help("Copy the ticket number")
                Spacer()
                if let onImplement {
                    Button(action: onImplement) {
                        Label("Implement with agent", systemImage: "sparkles")
                    }
                    .buttonStyle(AgentGradientButtonStyle())
                    .controlSize(.regular)
                    .help("Start a Claude session that implements this ticket")
                }
                if manual {
                    Button(role: .destructive, action: onUnlink) { Label("Unlink", systemImage: "link.badge.minus") }
                        .buttonStyle(.borderless)
                } else if let onHide {
                    Button(action: onHide) { Label("Hide", systemImage: "eye.slash") }
                        .buttonStyle(.borderless)
                        .help("Hide this ticket on this pull request")
                }
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(flat ? Color.clear : Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(flat ? Color.clear : Color.syLine))
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
        let blocks = JiraDescriptionBlock.parse(issue.description)
        let long = blocks.count > 9 || issue.description.count > 600
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DESCRIPTION").font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                Spacer()
                if editable {
                    Button { withAnimation(Motion.fade) { editingDescription = true } } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(JiraChipButtonStyle())
                        .controlSize(.small)
                        .help("Edit the description in Jira")
                }
            }
            JiraDescriptionView(blocks: expanded || !long ? blocks : Array(blocks.prefix(8)))
                .overlay(alignment: .bottom) {
                    if long && !expanded {
                        LinearGradient(colors: [Color.sySunken.opacity(0), Color.sySunken], startPoint: .top, endPoint: .bottom)
                            .frame(height: 36)
                            .allowsHitTesting(false)
                    }
                }
            if long {
                Button(expanded ? "Show less" : "Show more") { withAnimation(Motion.smooth) { expanded.toggle() } }
                    .buttonStyle(.link)
                    .font(.syCallout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.sySunken))
    }

    private var descriptionSkeleton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Description").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
            ShimmerBar(width: 120, height: 11)
            ShimmerBar(height: 11)
            ShimmerBar(height: 11)
            ShimmerBar(width: 260, height: 11)
            ShimmerBar(width: 200, height: 11)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySunken))
        .accessibilityLabel("Loading ticket details")
    }

    private var statusMenu: some View {
        Button {
            statusOpen.toggle()
            if transitions.isEmpty, !loadingTransitions { Task { await loadTransitions() } }
        } label: {
            JiraStatusPill(status: issue.status, category: issue.statusCategory, chevron: true, busy: moving)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { inside in
            guard inside, transitions.isEmpty, !loadingTransitions else { return }
            Task { await loadTransitions() }
        }
        .disabled(moving)
        .help("Change status")
        .popover(isPresented: $statusOpen, arrowEdge: .bottom) { statusPanel }
    }

    /// The board's columns when this ticket is on the board that is open, so the panel can show where a move lands.
    private var boardColumns: [JiraBoardColumn] {
        let model = JiraBoardModel.shared
        guard model.connectionID == issue.connectionID, let sid = issue.statusID else { return [] }
        let columns = model.snap.columns.filter { !$0.statusIDs.isEmpty }
        return columns.contains(where: { $0.statusIDs.contains(sid) }) ? columns : []
    }

    private func columnIndex(_ statusID: String?, in columns: [JiraBoardColumn]) -> Int? {
        guard let statusID else { return nil }
        return columns.firstIndex { $0.statusIDs.contains(statusID) }
    }

    private var orderedTransitions: [JiraTransition] {
        let columns = boardColumns
        guard !columns.isEmpty else { return transitions }
        return transitions.enumerated().sorted { a, b in
            (columnIndex(a.element.toID, in: columns) ?? 1000 + a.offset) < (columnIndex(b.element.toID, in: columns) ?? 1000 + b.offset)
        }.map(\.element)
    }

    private var statusPanel: some View {
        let columns = boardColumns
        return VStack(alignment: .leading, spacing: 2) {
            if !columns.isEmpty {
                JiraMiniBoard(columns: columns, issueKey: issue.key,
                              current: columnIndex(issue.statusID, in: columns),
                              target: hoverTransition.flatMap { t in columnIndex(t.toID, in: columns) },
                              targetName: hoverTransition?.to,
                              currentColor: JiraStyle.statusColor(issue.statusCategory),
                              targetColor: hoverTransition.map { JiraStyle.statusColor($0.toCategory) } ?? .syAgentAccent)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                Divider().padding(.bottom, 4)
            }
            Text("STATUS")
                .font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            JiraStatusRow(name: issue.status, detail: "current", category: issue.statusCategory, current: true) {}
            Divider().padding(.vertical, 4)
            Text("MOVE TO")
                .font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                .padding(.horizontal, 10).padding(.bottom, 2)
            if transitions.isEmpty {
                if loadingTransitions {
                    VStack(alignment: .leading, spacing: 10) {
                        ShimmerBar(width: 180, height: 12)
                        ShimmerBar(width: 220, height: 12)
                        ShimmerBar(width: 150, height: 12)
                    }
                    .padding(10)
                } else {
                    Text("No transitions available").font(.syCaption).foregroundStyle(Color.syMuted).padding(10)
                }
            } else {
                ForEach(orderedTransitions) { t in
                    JiraStatusRow(name: t.to, detail: t.name == t.to ? nil : "via “\(t.name)”", category: t.toCategory, current: false,
                                  onHover: { inside in
                                      if inside { hoverTransition = t } else if hoverTransition?.id == t.id { hoverTransition = nil }
                                  }) {
                        statusOpen = false
                        move(t)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: columns.isEmpty ? 270 : min(500, max(290, CGFloat(columns.count) * 62 + 16)))
        .onDisappear { hoverTransition = nil }
    }

    private func loadTransitions() async {
        guard let client = JiraConnections.shared.client(for: issue.connectionID) else { return }
        loadingTransitions = true
        transitions = (try? await client.transitions(issue.key)) ?? []
        loadingTransitions = false
    }

    private func move(_ t: JiraTransition) {
        guard let client = JiraConnections.shared.client(for: issue.connectionID) else { return }
        let id = issue.connectionID
        moving = true
        error = nil
        Task {
            do {
                try await client.transition(issue.key, to: t.id)
                var updated = try await client.issue(issue.key)
                updated.connectionID = id
                JiraConnections.shared.remember(updated)
                onChange(updated)
            } catch {
                self.error = error.localizedDescription
            }
            moving = false
        }
    }
}

private struct JiraStatusRow: View {
    let name: String
    let detail: String?
    let category: String
    let current: Bool
    var onHover: (Bool) -> Void = { _ in }
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let color = JiraStyle.statusColor(category)
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.opacity(current ? 0.18 : 0.1)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.syCallout.weight(current ? .semibold : .regular))
                        .foregroundStyle(Color.syText)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if current {
                    Image(systemName: "checkmark").font(.syCaption.weight(.bold)).foregroundStyle(Color.syAgentAccent).frame(width: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && !current ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!current)
        .onHover { hover = $0; onHover($0) }
        .accessibilityAddTraits(current ? [.isSelected] : [])
    }
}

/// Quiet rounded button for the ticket's secondary actions: subtle fill, brighter on hover, green after copying.
struct JiraChipButtonStyle: ButtonStyle {
    var done = false

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, done: done)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        let done: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let tint = done ? Color.syGreen : Color.syText
            configuration.label
                .labelStyle(ChipLabelStyle())
                .font(.syCallout.weight(.medium))
                .foregroundStyle(done ? Color.syGreen : (hover ? Color.syText : Color.syText.opacity(0.85)))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(configuration.isPressed ? 0.16 : (hover || done ? 0.1 : 0.05)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tint.opacity(hover || done ? 0.22 : 0.1))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onHover { hover = $0 }
                .animation(Motion.fade, value: hover)
                .animation(Motion.fade, value: done)
        }
    }

    private struct ChipLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 6) {
                configuration.icon.font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                configuration.title
            }
        }
    }
}

/// A Jira description split into what it reads as: headings ("Steps to Reproduce:"), bullets and paragraphs.
enum JiraDescriptionBlock: Equatable {
    case heading(String)
    case bullet(String)
    case paragraph(String)
    case gap

    static func parse(_ text: String) -> [JiraDescriptionBlock] {
        var blocks: [JiraDescriptionBlock] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let last = blocks.last, last != .gap { blocks.append(.gap) }
                continue
            }
            if line.hasPrefix("• ") || line.hasPrefix("- ") || line.hasPrefix("* ") {
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if isHeading(line) {
                if let last = blocks.last, last != .gap { blocks.append(.gap) }
                blocks.append(.heading(line.replacingOccurrences(of: "**", with: "")))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        // A gap right after a heading only pushes its content away.
        var out: [JiraDescriptionBlock] = []
        for b in blocks {
            if b == .gap, case .heading = out.last { continue }
            out.append(b)
        }
        while out.last == .gap { out.removeLast() }
        return out
    }

    static func isHeading(_ line: String) -> Bool {
        let plain = line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        guard !plain.isEmpty, plain.count <= 48 else { return false }
        if plain.hasSuffix(":") { return true }
        return line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4
    }
}

struct JiraDescriptionView: View {
    let blocks: [JiraDescriptionBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(t)
                        .font(.syBody.weight(.semibold))
                        .foregroundStyle(Color.syText)
                        .padding(.top, 2)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(Color.syMuted).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        rich(t)
                    }
                    .padding(.leading, 4)
                case .paragraph(let t):
                    rich(t)
                case .gap:
                    Color.clear.frame(height: 6)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rich(_ t: String) -> some View {
        let attributed = (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
        return Text(attributed)
            .font(.syBody)
            .lineSpacing(3)
            .foregroundStyle(Color.syText.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tiny picture of the board: where the ticket is now and, while a status is hovered, where it would go.
struct JiraMiniBoard: View {
    let columns: [JiraBoardColumn]
    let issueKey: String
    let current: Int?
    let target: Int?
    let targetName: String?
    var currentColor: Color = .syText
    var targetColor: Color = .syAgentAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(columns.enumerated()), id: \.offset) { i, column in
                    lane(i, column)
                }
            }
            HStack(spacing: 5) {
                Text(issueKey).font(.syCaption2.weight(.semibold).monospaced()).foregroundStyle(Color.syMuted)
                if let current {
                    Text(columns[current].name).font(.syCaption2.weight(.semibold)).foregroundStyle(currentColor)
                }
                if let target, target != current {
                    Image(systemName: "arrow.right").font(.syCaption2.weight(.bold)).foregroundStyle(targetColor)
                    Text(columns[target].name).font(.syCaption2.weight(.semibold)).foregroundStyle(targetColor)
                } else if targetName != nil, target == nil {
                    Image(systemName: "arrow.right").font(.syCaption2.weight(.bold)).foregroundStyle(targetColor)
                    Text("\(targetName ?? "") · not on this board").font(.syCaption2.weight(.semibold)).foregroundStyle(targetColor)
                } else {
                    Text("· hover a status to see where it goes").font(.syCaption2).foregroundStyle(Color.syDim)
                }
            }
            .lineLimit(1)
        }
        .animation(Motion.fade, value: target)
    }

    private func lane(_ i: Int, _ column: JiraBoardColumn) -> some View {
        let isCurrent = i == current
        let isTarget = i == target && target != current
        let moving = target != nil && target != current
        return VStack(spacing: 4) {
            Text(column.name)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(isTarget ? targetColor : (isCurrent ? currentColor : Color.syDim))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTarget ? targetColor.opacity(0.12) : Color.syText.opacity(0.05))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isTarget ? targetColor.opacity(0.6) : Color.syLine, style: StrokeStyle(lineWidth: 1, dash: isTarget ? [3, 2] : []))
                VStack(spacing: 3) {
                    if isCurrent {
                        card(currentColor.opacity(moving ? 0.3 : 0.85))
                    }
                    if isTarget {
                        card(targetColor)
                    }
                    if !isCurrent && !isTarget {
                        RoundedRectangle(cornerRadius: 2).fill(Color.syText.opacity(0.06)).frame(height: 7).padding(.horizontal, 6)
                    }
                }
            }
            .frame(height: 26)
        }
        .frame(maxWidth: .infinity)
    }

    private func card(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(height: 12)
            .padding(.horizontal, 6)
    }
}
