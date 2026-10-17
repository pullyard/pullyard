import SwiftUI

struct PRDetailView: View {
    let ref: ItemRef
    @Environment(AppModel.self) private var app
    @State private var model: PRDetailModel?

    var body: some View {
        Group {
            if let model {
                if model.notPR {
                    IssueDetailView(ref: ref)
                } else if let pr = model.pr {
                    PRDetailContent(model: model, pr: pr)
                } else if let e = model.error {
                    ErrorStateView(message: e) { Task { await model.load() } }
                } else if model.tab == .stack, let tree = model.stackTree, let node = model.preview {
                    StackPreviewContent(model: model, node: node, tree: tree)
                } else {
                    LoadingView()
                }
            } else {
                LoadingView()
            }
        }
        .task(id: "\(ref.repo.full)#\(ref.number)|\(app.account?.id ?? app.user?.login ?? "")") {
            let m = app.prModel(ref)
            model = m
            await m?.load(live: m?.pr != nil)
        }
        .onChange(of: app.refreshTick) {
            Task { await model?.load(full: true) }
        }
        .onLiveTick { await model?.load(live: true) }
    }
}

enum PRConfirm: Identifiable {
    case approve, revokeApproval, close, deleteBranch, disableAutoMerge, rerunFailed
    var id: Int { hashValue }
}

struct PRDetailContent: View {
    @Bindable var model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(AppModel.self) private var app
    @State private var showReview = false
    @State private var showMerge = false
    @State private var showEdit = false
    @State private var showReviewers = false
    @State private var confirm: PRConfirm?
    @State private var showFix = false
    @State private var ciFix: CIFixRequest?

    var body: some View {
        VStack(spacing: 0) {
            PRHeaderView(model: model, pr: pr, onMerge: { showMerge = true }, onRequestReview: { showReviewers = true })
            if model.features.requestReviewers {
                ReReviewBanner(model: model, pr: pr) { showReviewers = true }
            }
            if model.features.claude {
                ClaudeFixBanner(pr: pr) { showFix = true }
                CIFailureBanner(model: model, pr: pr, onFix: { ciFix = CIFixRequest() }, onRerun: { confirm = .rerunFailed })
            }
            TabStrip(items: tabItems, selection: $model.tab, shortcuts: true)
            .padding(.top, 6)
            Divider()
            ZStack {
                ForEach(PRTab.allCases) { tab in
                    if model.visitedTabs.contains(tab), tab != .stack || model.tab == .stack {
                        tabContent(tab)
                            .opacity(model.tab == tab ? 1 : 0)
                            .animation(Motion.fade, value: model.tab)
                            .allowsHitTesting(model.tab == tab)
                            .disabled(model.tab != tab)
                            .accessibilityHidden(model.tab != tab)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(pr.title)
        .navigationSubtitle("\(model.ref.repo.full) \(model.provider.numberPrefix)\(pr.number)")
        .task(id: pr.url) { app.noteCanonical(model.ref, url: pr.url) }
        .panelToolbar(id: "pr-detail") { toolbar }
        .sheet(isPresented: $showReview) { ReviewSheet(model: model, pr: pr) }
        .sheet(isPresented: $showMerge) { MergeSheet(model: model, pr: pr) }
        .sheet(isPresented: $showEdit) { EditPRSheet(model: model, pr: pr) }
        .sheet(isPresented: $showReviewers) { ReviewersSheet(model: model) }
        .sheet(isPresented: $showFix) { FixWithClaudeSheet(model: model, pr: pr) }
        .sheet(item: $ciFix) { FixWithClaudeSheet(model: model, pr: pr, ci: $0) }
        .sheet(isPresented: $model.showResolveConflicts) { ResolveConflictsSheet(model: model, pr: pr) }
        .sheet(item: $model.replyThread) { ReplySheet(model: model, thread: $0) }
        .alert("Couldn’t complete the action", isPresented: Binding(get: { model.actionError != nil && model.sheetDepth == 0 }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.actionError ?? "")
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { c in
            Button(confirmButton(c), role: c == .approve || c == .rerunFailed || c == .revokeApproval ? nil : .destructive) { perform(c) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: PRTab) -> some View {
        switch tab {
        case .conversation: ConversationTab(model: model, pr: pr)
        case .commits: CommitsTab(model: model, pr: pr)
        case .checks: ChecksTab(model: model, pr: pr, onFix: { ciFix = $0 }, onRerun: { confirm = .rerunFailed })
        case .files: FilesTab(model: model)
        case .stack:
            if let tree = model.stackTree {
                StackTab(model: model, tree: tree)
            } else {
                LoadingView()
            }
        case .jira: JiraTab(pr: pr)
        }
    }

    private var tabItems: [TabItem<PRTab>] {
        var items = [
            TabItem(id: PRTab.conversation, title: "Conversation", icon: "bubble.left.and.bubble.right", badge: commentsBadge),
            TabItem(id: PRTab.commits, title: "Commits", icon: "point.3.connected.trianglepath.dotted", badge: "\(pr.allCommits.totalCount ?? pr.allCommits.nodes.count)"),
            TabItem(id: PRTab.checks, title: model.features.checksTitle, icon: "checklist", badge: checksSummary, badgeColor: checksColor, badgeLabel: checksSpoken),
            TabItem(id: PRTab.files, title: "Files changed", icon: "doc.text", badge: "\(pr.changedFiles)")
        ]
        if let tree = model.stackTree {
            items.append(TabItem(id: PRTab.stack, title: "Stack", icon: "square.stack.3d.up", badge: "\(tree.count)"))
        }
        let jiraKeys = JiraTab.keys(for: pr)
        if JiraAccount.shared.isConfigured || !jiraKeys.isEmpty {
            items.append(TabItem(id: PRTab.jira, title: "Jira", icon: "ticket", badge: jiraKeys.first))
        }
        return items
    }

    private var commentsBadge: String? {
        let unresolved = pr.reviewThreads.nodes.filter { !$0.isResolved && !$0.isOutdated }.count
        return unresolved > 0 ? "\(unresolved)" : nil
    }

    private var checksColor: Color {
        let checks = pr.checks
        if checks.contains(where: { $0.outcome == .failure }) { return .ghRed }
        if checks.contains(where: { $0.outcome == .pending }) { return .ghYellow }
        return checks.isEmpty ? .secondary : .ghGreen
    }

    private var checksSpoken: String {
        let checks = pr.checks
        let failed = checks.filter { $0.outcome == .failure }.count
        let pending = checks.filter { $0.outcome == .pending }.count
        if checks.isEmpty { return "no checks" }
        if failed > 0 { return "\(failed) failing" }
        if pending > 0 { return "\(pending) running" }
        return "all \(checks.count) passed"
    }

    private var checksSummary: String {
        let checks = pr.checks
        if checks.isEmpty { return "0" }
        let failed = checks.filter { $0.outcome == .failure }.count
        let pending = checks.filter { $0.outcome == .pending }.count
        if failed > 0 { return "✕\(failed)" }
        if pending > 0 { return "…\(pending)" }
        return "✓\(checks.count)"
    }

    private var confirmTitle: String {
        switch confirm {
        case .approve: return model.pending.isEmpty ? "Approve this \(model.provider.requestTitle)?" : "Approve and submit \(plural(model.pending.count, "pending comment", "pending comments"))?"
        case .revokeApproval: return "Revoke your approval?"
        case .close: return "Close \(model.provider.requestTitle) without merging?"
        case .deleteBranch: return "Delete branch \(pr.headRefName)?"
        case .disableAutoMerge: return "Disable auto-merge?"
        case .rerunFailed:
            let runs = Set(pr.checks.filter { $0.outcome == .failure }.compactMap(\.runId)).count
            return "Re-run failed jobs in \(plural(runs, "workflow run", "workflow runs"))?"
        case nil: return ""
        }
    }

    private func confirmButton(_ c: PRConfirm) -> String {
        switch c {
        case .approve: return model.pending.isEmpty ? "Approve" : "Approve and submit"
        case .revokeApproval: return "Revoke approval"
        case .close: return "Close \(model.provider.requestTitle)"
        case .deleteBranch: return "Delete branch"
        case .disableAutoMerge: return "Disable"
        case .rerunFailed: return "Re-run failed jobs"
        }
    }

    private func perform(_ c: PRConfirm) {
        Task {
            switch c {
            case .approve: _ = await model.submitReview(event: "APPROVE", body: "")
            case .revokeApproval: await model.revokeApproval()
            case .close: await model.simple(.close)
            case .deleteBranch: await model.deleteBranch()
            case .disableAutoMerge: await model.simple(.disableAutoMerge)
            case .rerunFailed: await model.rerunFailed()
            }
        }
    }

    private var canMerge: Bool {
        pr.isOpen && !pr.isDraft && model.canWrite
    }

    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "pr.status", placement: .primaryAction) {
            HStack(spacing: 6) {
                if model.busy {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await model.load(full: true) }
                } label: {
                    RefreshStatus(updated: model.lastUpdated, refreshing: model.loading, error: model.refreshError, compact: true)
                }
                .buttonStyle(.borderless)
                .disabled(model.loading)
                .help(model.refreshError.map { "Last refresh failed: \($0). Click to retry (⌘R)" } ?? "Refresh (⌘R)")
                .accessibilityLabel("Refresh")
            }
        }
        if pr.isOpen {
            ToolbarItem(id: "pr.review", placement: .primaryAction) {
                Menu {
                    Button("Write review…") { showReview = true }
                    if pr.viewerCanApprove ?? !pr.viewerDidAuthor, pr.viewerApproved != true {
                        Button("Approve") { confirm = .approve }
                    }
                    if model.features.revokeApproval, pr.viewerApproved == true {
                        Button("Revoke approval") { confirm = .revokeApproval }
                    }
                    if model.features.requestReviewers {
                        Divider()
                        Button("Request review…") { showReviewers = true }
                    }
                } label: {
                    Label(model.pending.isEmpty ? "Review" : "Review (\(model.pending.count))", systemImage: "checkmark.bubble")
                } primaryAction: {
                    showReview = true
                }
                .labelStyle(.titleAndIcon)
                .help(model.pending.isEmpty ? "Write a review" : "Submit review with \(plural(model.pending.count, "pending comment", "pending comments"))")
            }
            if model.features.requestReviewers {
                ToolbarItem(id: "pr.requestReview", placement: .primaryAction, showsByDefault: false) {
                    Button { showReviewers = true } label: { Label("Request review", systemImage: "person.crop.circle.badge.plus") }
                        .help("Request or re-request review")
                }
            }
        }
        if pr.isOpen, model.features.claude {
            ToolbarItem(id: "pr.fix", placement: .primaryAction) {
                Button { showFix = true } label: { Label("Fix with agent", systemImage: "wrench.and.screwdriver") }
                    .labelStyle(.titleAndIcon)
                    .help("Send review comments to a new agent session")
            }
        }
        if canMerge {
            ToolbarItem(id: "pr.merge", placement: .primaryAction) {
                Button { showMerge = true } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                    .labelStyle(.titleAndIcon)
                    .help("Merge \(model.provider.requestTitle)")
            }
        }
        ToolbarItem(id: "pr.more", placement: .primaryAction) {
            ControlGroup {
                Button { openInBrowser(pr.url) } label: { Label("Open in browser", systemImage: "safari") }
                    .help(model.provider.isGitHub && model.provider != .githubEnterprise ? "Open on github.com" : "Open on \(model.features.serviceTitle)")
                Menu {
                    moreMenu
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More actions")
            } label: {
                Label("Browser and more", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Button("Copy link") { copyToPasteboard(pr.url) }
        if model.provider.isGitHub {
            Button("Copy short link") { app.copyShortLink(ShortLink.ref(url: pr.url) ?? model.ref) }
            Button("Copy “gh pr checkout \(pr.number)”") { copyToPasteboard("gh pr checkout \(pr.number) -R \(model.ref.repo.full)") }
        } else if model.provider == .gitlab {
            Button("Copy “glab mr checkout \(pr.number)”") { copyToPasteboard("glab mr checkout \(pr.number) -R \(model.ref.repo.full)") }
        }
        Button("Copy branch name") { copyToPasteboard(pr.headRefName) }
        Divider()
        if pr.viewerCanUpdate, model.features.editing {
            Button("Edit title and description…") { showEdit = true }
        }
        if pr.isOpen {
            if pr.viewerCanUpdate, model.features.draftToggle {
                if pr.isDraft {
                    Button(model.provider == .gitlab ? "Mark as ready" : "Ready for review") { Task { if await model.simple(.readyForReview) { app.showToast("Marked ready for review") } } }
                } else {
                    Button(model.provider == .gitlab ? "Mark as draft" : "Convert to draft") { Task { if await model.simple(.convertToDraft) { app.showToast("Converted to draft") } } }
                }
            }
            if model.features.claude, model.features.localConflicts, MergeConflicts.applies(pr) {
                Button("Resolve conflicts with agent…") { model.showResolveConflicts = true }
            }
            if model.features.updateBranch, model.provider == .gitlab ? pr.mergeStateStatus == "BEHIND" : pr.mergeStateStatus == "BEHIND" || pr.mergeStateStatus == "BLOCKED" || pr.mergeStateStatus == "UNSTABLE" {
                Button(model.provider == .gitlab ? "Rebase onto \(pr.baseRefName)" : "Update branch from \(pr.baseRefName)") { Task { if await model.simple(.updateBranch) { app.showToast(model.provider == .gitlab ? "Rebase started" : "Branch updated from \(pr.baseRefName)") } } }
            }
            if pr.autoMergeRequest != nil {
                Button("Disable auto-merge") { confirm = .disableAutoMerge }
            }
            Divider()
            if pr.viewerCanUpdate {
                Button("Close \(model.provider.requestTitle)…") { confirm = .close }
            }
        } else if !pr.merged, pr.viewerCanUpdate {
            Button("Reopen \(model.provider.requestTitle)") { Task { if await model.simple(.reopen) { app.showToast(model.provider == .gitlab ? "Merge request reopened" : "Pull request reopened") } } }
        }
        if model.features.deleteBranch, !pr.isOpen, pr.headRef != nil, model.canWrite {
            Button("Delete branch \(pr.headRefName)…") { confirm = .deleteBranch }
        }
    }
}

struct StackPreviewContent: View {
    let model: PRDetailModel
    let node: StackNode
    let tree: StackTree

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(node.title).font(.syTitle2.weight(.bold)).lineLimit(1)
                    Text("#\(node.number)").font(.syTitle2).foregroundStyle(Color.syDim)
                    PullYardLoader(size: 22)
                }
                HStack(spacing: 8) {
                    StateBadge(state: node.visualState)
                    Text(node.author ?? "").fontWeight(.semibold)
                    BranchChip(name: node.baseRefName)
                    Image(systemName: "arrow.left").font(.syCaption).foregroundStyle(Color.syDim)
                    BranchChip(name: node.headRefName, color: .syViolet)
                    Spacer(minLength: 0)
                    ShimmerBar(width: 70, height: 12)
                }
                .font(.syCallout)
                .lineLimit(1)
                StackStrip(tree: tree, repo: model.ref.repo) {}
                ShimmerBar(height: 30, radius: 9)
                ShimmerBar(height: 30, radius: 9)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            HStack(spacing: 14) {
                ForEach([96, 80, 70, 110], id: \.self) { ShimmerBar(width: CGFloat($0), height: 14) }
                Label("Stack", systemImage: "square.stack.3d.up").font(.syCallout.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .padding(.top, 6)
            Divider()
            StackTab(model: model, tree: tree)
        }
        .navigationTitle(node.title)
        .navigationSubtitle("\(model.ref.repo.full) #\(node.number)")
    }
}

struct PRHeaderView: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onMerge: () -> Void
    var onRequestReview: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pr.title).font(.syTitle2.weight(.bold)).textSelection(.enabled)
                Text("\(model.provider.numberPrefix)\(pr.number)").font(.syTitle2).foregroundStyle(Color.syDim)
                if model.provider.isGitHub {
                    ShortLinkButton(ref: ShortLink.ref(url: pr.url) ?? model.ref)
                }
            }
            HStack(spacing: 8) {
                StateBadge(state: pr.visualState)
                Avatar(url: pr.author?.avatarUrl, size: 18)
                Text(pr.author?.login ?? "ghost").fontWeight(.semibold)
                BranchChip(name: pr.baseRefName)
                Image(systemName: "arrow.left").font(.syCaption).foregroundStyle(Color.syDim)
                BranchChip(name: pr.headRefName, color: .syViolet)
                if let stat = model.diffStat {
                    DiffStat(additions: stat.additions, deletions: stat.deletions)
                }
                Spacer(minLength: 0)
                Text(Fmt.rel(pr.createdAt)).foregroundStyle(Color.syMuted).help(Fmt.full.string(from: pr.createdAt))
            }
            .font(.syCallout)
            .lineLimit(1)
            if !pr.labels.nodes.isEmpty || !model.reviewers.isEmpty || !pr.assignees.nodes.isEmpty {
                HStack(spacing: 6) {
                    ForEach(pr.labels.nodes, id: \.name) { LabelChip(label: $0) }
                    if !model.reviewers.isEmpty {
                        Text("Reviewers:").font(.syCaption).foregroundStyle(Color.syMuted).padding(.leading, pr.labels.nodes.isEmpty ? 0 : 6)
                        ForEach(model.reviewers, id: \.login) { r in
                            ReviewerBadge(login: r.login, avatar: r.avatar, state: r.state)
                        }
                    }
                    if !pr.assignees.nodes.isEmpty {
                        Text("Assignees:").font(.syCaption).foregroundStyle(Color.syMuted).padding(.leading, 6)
                        ForEach(pr.assignees.nodes, id: \.login) { a in
                            Avatar(url: a.avatarUrl, size: 18).help(a.login)
                        }
                    }
                }
            }
            if let tree = model.stackTree {
                StackStrip(tree: tree, repo: model.ref.repo) { model.tab = .stack }
                    .transition(.opacity)
            }
            MergeStatusBar(model: model, pr: pr, onMerge: onMerge, onRequestReview: onRequestReview)
        }
        .animation(Motion.smooth, value: model.stackTree)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct StackStrip: View {
    let tree: StackTree
    let repo: RepoRef
    let onShow: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let line = tree.line
        let index = line.firstIndex { $0.number == tree.current } ?? 0
        let ups = (tree.children[tree.current] ?? []).compactMap { tree.nodes[$0] }
        HStack(spacing: 8) {
            Button(action: onShow) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.syIndigo)
                    Text("Stack").fontWeight(.semibold)
                    Text("\(index + 1) of \(line.count)").foregroundStyle(Color.syMuted)
                    HStack(spacing: 3) {
                        ForEach(line) { s in
                            Capsule()
                                .fill(s.number == tree.current ? Color.syIndigo : s.visualState.color.opacity(0.55))
                                .frame(width: s.number == tree.current ? 18 : 10, height: 5)
                        }
                    }
                    if tree.count > line.count {
                        Text("+\(tree.count - line.count)").font(.syCaption).foregroundStyle(Color.syMuted)
                            .help(plural(tree.count - line.count, "more pull request on another branch of the stack", "more pull requests on other branches of the stack"))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the whole stack")
            if let down = tree.parent[tree.current].flatMap({ tree.nodes[$0] }) {
                navButton(down, icon: "chevron.down", help: "Down the stack")
            }
            if ups.count == 1, let up = ups.first {
                navButton(up, icon: "chevron.up", help: "Up the stack")
            } else if ups.count > 1 {
                Menu {
                    ForEach(ups) { s in
                        Button("#\(s.number) \(s.title)") { app.open(.pr(ItemRef(repo: repo, number: s.number))) }
                    }
                } label: {
                    Label("\(ups.count)", systemImage: "chevron.up").labelStyle(.titleAndIcon).font(.syCaption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Up the stack: \(ups.count) pull requests are stacked on this one")
                .accessibilityLabel("Up the stack: \(ups.count) pull requests are stacked on this one")
            }
            Button(action: onShow) {
                Image(systemName: "chevron.right").font(.syCaption2).foregroundStyle(Color.syDim)
            }
            .buttonStyle(.plain)
            .help("Show stack")
            .accessibilityLabel("Show stack")
        }
        .font(.syCallout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.syIndigo.opacity(0.06)))
    }

    private func navButton(_ s: StackNode, icon: String, help: String) -> some View {
        Button {
            app.open(.pr(ItemRef(repo: repo, number: s.number)))
        } label: {
            Label("#\(s.number)", systemImage: icon).labelStyle(.titleAndIcon).font(.syCaption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .help("\(help): #\(s.number) \(s.title)")
        .accessibilityLabel("\(help): #\(s.number) \(s.title)")
    }
}

struct BranchChip: View {
    let name: String
    var color: Color = .sySky

    var body: some View {
        Text(name)
            .font(.syCaption.monospaced())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
            .onTapGesture { copyToPasteboard(name) }
            .help("Click to copy")
    }
}

struct ReviewerBadge: View {
    let login: String
    let avatar: String?
    let state: String

    var body: some View {
        HStack(spacing: 3) {
            Avatar(url: avatar, size: 18)
            Group {
                switch state {
                case "APPROVED": Image(systemName: "checkmark").foregroundStyle(Color.ghGreen)
                case "CHANGES_REQUESTED": Image(systemName: "plusminus").foregroundStyle(Color.ghRed)
                case "COMMENTED": Image(systemName: "text.bubble").foregroundStyle(Color.syMuted)
                default: Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Color.ghYellow)
                }
            }
            .font(.syCaption.weight(.bold))
        }
        .help("\(login): \(stateTitle)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(login): \(stateTitle)")
    }

    private var stateTitle: String {
        switch state {
        case "APPROVED": return "approved"
        case "CHANGES_REQUESTED": return "changes requested"
        case "COMMENTED": return "commented"
        case "DISMISSED": return "dismissed"
        default: return "review pending"
        }
    }
}

struct MergeStatusBar: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onMerge: () -> Void
    var onRequestReview: () -> Void = {}
    @Environment(AppModel.self) private var app
    @AppStorage("pr.mergeRequirementsExpanded") private var expanded = true

    var body: some View {
        if pr.isOpen {
            let requirements = model.requirements
            let s = Self.status(pr, requirements: requirements)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: s.icon).foregroundStyle(s.color).accessibilityHidden(true)
                    Text(s.text).font(.syCallout).lineLimit(2)
                    if let auto = pr.autoMergeRequest {
                        Text("· auto-merge enabled" + (auto.mergeMethod.map { " (\(MergeMethod(rawValue: $0)?.title ?? $0))" } ?? ""))
                            .font(.syCallout).foregroundStyle(Color.ghGreen)
                    }
                    checksBadge
                    Spacer()
                    if model.features.localConflicts, MergeConflicts.applies(pr) {
                        Button(conflictsTitle) {
                            model.tab = .conversation
                            model.scrollToBottomToken += 1
                        }
                        .controlSize(.small)
                        .help("Show the conflicting files at the end of the conversation")
                    }
                    if model.features.updateBranch, pr.mergeStateStatus == "BEHIND", model.canWrite || pr.viewerCanUpdate {
                        Button(model.features.updateBranchTitle) {
                            Task { if await model.simple(.updateBranch) { app.showToast(model.provider == .gitlab ? "Rebase started" : "Branch updated from \(pr.baseRefName)") } }
                        }
                        .controlSize(.small)
                    }
                    if pr.isDraft, pr.viewerCanUpdate, model.features.draftToggle {
                        Button(model.provider == .gitlab ? "Mark as ready" : "Ready for review") {
                            Task { if await model.simple(.readyForReview) { app.showToast("Marked ready for review") } }
                        }
                        .controlSize(.small)
                        .help("Mark this draft as ready for review")
                    }
                    if model.canWrite, !pr.isDraft {
                        if s.ready {
                            Button("Merge…", action: onMerge)
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                                .tint(Color.syGreenFill)
                        } else {
                            Button("Merge…", action: onMerge)
                                .controlSize(.small)
                                .help("Not ready to merge: \(s.text)")
                        }
                    }
                    if !requirements.isEmpty {
                        Button {
                            withAnimation(Motion.smooth) { expanded.toggle() }
                        } label: {
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(expanded ? 0 : -90))
                                .font(.syCaption.weight(.semibold))
                                .foregroundStyle(Color.syMuted)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide merge requirements" : "Show merge requirements")
                        .accessibilityLabel(expanded ? "Hide merge requirements" : "Show merge requirements")
                    }
                }
                if expanded, !requirements.isEmpty {
                    MergeRequirementsList(requirements: requirements, ownership: model.ownership, canPerform: canPerform, perform: perform)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Radius.m).fill(s.color.opacity(Tint.banner)))
            .accessibilityElement(children: .contain)
        }
    }

    private func canPerform(_ action: RequirementAction) -> Bool {
        switch action {
        case .requestReview: return model.features.requestReviewers && (model.canWrite || pr.viewerDidAuthor)
        case .updateBranch, .readyForReview: return false
        case .showConflicts: return !MergeConflicts.applies(pr)
        case .showChecks, .showConversation: return true
        }
    }

    private func perform(_ action: RequirementAction) {
        switch action {
        case .requestReview: onRequestReview()
        case .showChecks: model.tab = .checks
        case .showConversation: model.tab = .conversation
        case .showConflicts:
            model.tab = .conversation
            model.scrollToBottomToken += 1
        case .updateBranch:
            Task { if await model.simple(.updateBranch) { app.showToast("Branch updated from \(pr.baseRefName)") } }
        case .readyForReview:
            Task { if await model.simple(.readyForReview) { app.showToast("Marked ready for review") } }
        }
    }

    @ViewBuilder
    private var checksBadge: some View {
        let checks = pr.checks
        if !checks.isEmpty {
            let failed = checks.filter { $0.outcome == .failure }.count
            let pending = checks.filter { $0.outcome == .pending }.count
            let ok = checks.filter { $0.outcome == .success }.count
            Button {
                model.tab = .checks
            } label: {
                HStack(spacing: 6) {
                    if failed > 0 { Label("\(failed)", systemImage: "xmark.circle.fill").foregroundStyle(Color.ghRed) }
                    if pending > 0 { Label("\(pending)", systemImage: "clock.fill").foregroundStyle(Color.ghYellow) }
                    Label("\(ok)", systemImage: "checkmark.circle.fill").foregroundStyle(Color.ghGreen)
                }
                .font(.syCaption)
            }
            .buttonStyle(.plain)
            .help(model.features.checksTitle)
            .accessibilityLabel(model.features.checksTitle)
            .accessibilityValue("\(failed) failed, \(pending) pending, \(ok) passed")
        }
    }

    private var conflictsTitle: String {
        let count = model.conflicts?.files.count ?? 0
        return count > 0 ? "View \(plural(count, "conflict", "conflicts"))" : "View conflicts"
    }

    static func status(_ pr: PullRequestDetail, requirements: [MergeRequirement] = []) -> (icon: String, color: Color, text: String, ready: Bool) {
        let breakdown = MergeReadiness.checks(pr.checks, rules: nil)
        let noun = breakdown.requiredKnown ? "required check" : "check"
        let failedChecks = breakdown.failedRequired.count
        let pendingChecks = breakdown.runningRequired.count
        let failedChecksText = failedChecks == 1 ? "1 \(noun) failed" : "\(failedChecks) \(noun)s failed"
        let pendingChecksText = pendingChecks == 1 ? "1 \(noun) is still running" : "\(pendingChecks) \(noun)s are still running"
        let unstableFailed = pr.checks.filter { $0.outcome == .failure }.count
        let unstablePending = pr.checks.filter { $0.outcome == .pending }.count
        if pr.isDraft { return ("pencil.circle", .sySlate, "Draft — mark it ready for review to merge", false) }
        if pr.mergeable == "CONFLICTING" || pr.mergeStateStatus == "DIRTY" {
            return ("exclamationmark.triangle.fill", .ghRed, "Has conflicts with \(pr.baseRefName)", false)
        }
        switch pr.mergeStateStatus {
        case "BEHIND": return ("arrow.down.circle", .ghYellow, "Branch is behind \(pr.baseRefName)", false)
        case "BLOCKED":
            if let blocker = pr.mergeBlocker {
                let pipeline = blocker.hasPrefix("Pipeline")
                return (pipeline && failedChecks == 0 ? "clock" : "lock.circle", .ghYellow, pipeline && failedChecks > 0 ? failedChecksText : blocker, false)
            }
            switch pr.reviewDecision {
            case "CHANGES_REQUESTED": return ("plusminus.circle.fill", .ghRed, "Changes requested", false)
            case "REVIEW_REQUIRED": return ("eye.circle", .ghYellow, "Review required", false)
            default:
                if failedChecks > 0 { return ("xmark.circle.fill", .ghRed, failedChecksText, false) }
                if let first = requirements.first(where: { $0.state == .missing }) { return ("lock.circle", .ghYellow, first.title, false) }
                if pendingChecks > 0 { return ("clock", .ghYellow, pendingChecksText, false) }
                if let first = requirements.first(where: { $0.state == .pending }) { return ("clock", .ghYellow, first.title, false) }
                return ("lock.circle", .ghYellow, "Blocked by branch protection", false)
            }
        case "UNSTABLE":
            let text = unstableFailed == 1 ? "1 check failed" : "\(unstableFailed) checks failed"
            if unstableFailed > 0 { return ("exclamationmark.circle", .ghYellow, "Can be merged, but " + text, true) }
            if unstablePending > 0 { return ("clock", .ghYellow, unstablePending == 1 ? "1 check is still running" : "\(unstablePending) checks are still running", true) }
            return ("checkmark.circle.fill", .ghGreen, "Ready to merge", true)
        case "CLEAN", "HAS_HOOKS": return ("checkmark.circle.fill", .ghGreen, "Ready to merge", true)
        default: return ("hourglass", .sySlate, "Checking mergeability…", false)
        }
    }
}

struct ConversationTab: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(AppModel.self) private var app
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HTMLView(html: model.html, scrollToBottomToken: model.scrollToBottomToken, onAction: handle, onLink: openLink)
                .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, web: true, button: false) { await model.load(full: true) }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                ComposerBox(text: $text, placeholder: "Comment (Markdown) — ⌘↩ to send", minHeight: 56).frame(height: 64)
                VStack(spacing: 6) {
                    CommentSendButton(text: text, busy: model.busy, action: send)
                }
            }
            .padding(10)
        }
    }

    private func send() {
        let body = text
        Task {
            if await model.comment(body) { text = "" }
        }
    }

    private func handle(_ type: String, _ id: String) {
        switch type {
        case "reply":
            model.replyThread = pr.reviewThreads.nodes.first { $0.id == id }
        case "resolve":
            Task { await model.setResolved(id, true) }
        case "unresolve":
            Task { await model.setResolved(id, false) }
        case "file":
            model.revealFile(id)
            Task { await model.loadFiles() }
        case "resolveConflicts":
            model.showResolveConflicts = true
        case "chooseClone":
            model.chooseLocalClone()
        case "rescanConflicts":
            model.rescanConflicts()
        default:
            break
        }
    }

    private func openLink(_ url: URL) {
        if url.host == "github.com", url.path == "/" || url.path.isEmpty { return }
        if let route = GitHubURL.parse(url.absoluteString, allowShort: false) {
            app.open(route, push: true)
        } else {
            LinkBrowser.open(url)
        }
    }
}

struct CommitsTab: View {
    let model: PRDetailModel
    let pr: PullRequestDetail

    var body: some View {
        List {
            ForEach(pr.allCommits.nodes.reversed(), id: \.commit.oid) { node in
                let c = node.commit
                NavigationLink(value: Route.commit(model.ref.repo, c.oid)) {
                    HStack(spacing: 10) {
                        Avatar(url: c.author?.avatarUrl, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.messageHeadline).font(.syBody).lineLimit(2)
                            Text("\(c.author?.user?.login ?? c.author?.name ?? "") · \(Fmt.rel(c.committedDate))")
                                .font(.syCaption).foregroundStyle(Color.syMuted)
                        }
                        Spacer()
                        CIIcon(state: c.statusCheckRollup?.state)
                        Text(c.abbreviatedOid).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
                    }
                    .padding(.vertical, 2)
                    .rowAppear(c.oid, model.commitRows)
                }
                .contextMenu {
                    Button("Copy SHA") { copyToPasteboard(c.oid) }
                    Button("Open in browser") { openInBrowser(c.url) }
                }
            }
            if (pr.allCommits.totalCount ?? 0) > pr.allCommits.nodes.count {
                Button("Show all \(pr.allCommits.totalCount ?? 0) commits in browser") { openInBrowser(pr.url + "/commits") }
            }
        }
        .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, button: false) { await model.load(full: true) }
    }
}

struct ChecksTab: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onFix: (CIFixRequest) -> Void
    let onRerun: () -> Void
    @State private var logTarget: CheckContext?
    @State private var fixAfterLog: CIFixRequest?

    var body: some View {
        let checks = pr.checks.sorted { ($0.outcome.rawValue, $0.title) < ($1.outcome.rawValue, $1.title) }
        let failedRuns = Set(checks.filter { $0.outcome == .failure }.compactMap(\.runId))
        List {
            if checks.isEmpty {
                Text(model.provider == .gitlab ? "No pipeline for the latest commit" : "No checks for the latest commit").font(.syBody).foregroundStyle(Color.syMuted)
            }
            if model.features.rerunChecks, !failedRuns.isEmpty, model.canWrite {
                Button(action: onRerun) {
                    Label("Re-run failed jobs (\(plural(failedRuns.count, "workflow", "workflows")))", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
            }
            ForEach(checks) { c in
                HStack(spacing: 10) {
                    OutcomeIcon(outcome: c.outcome)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.workflowName.map { "\($0) / \(c.title)" } ?? c.title).font(.syBody).lineLimit(1)
                        Text(subtitle(c)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                    }
                    Spacer()
                    if model.features.claude, CIFailureCollector.isFixable(c), pr.isOpen {
                        Button("Fix with agent") { onFix(CIFixRequest(focus: c.id)) }
                            .controlSize(.small)
                            .tint(Color.syCoral)
                    }
                    if model.features.jobLogs, c.isActionsJob, c.outcome != .pending, c.outcome != .skipped {
                        Button("Log") { logTarget = c }.controlSize(.small)
                    }
                    if let link = c.link {
                        Button { openInBrowser(link) } label: { Image(systemName: "arrow.up.right.square") }
                            .buttonStyle(.borderless)
                            .help("Open in browser")
                            .accessibilityLabel("Open in browser")
                    }
                }
                .padding(.vertical, 2)
                .rowAppear(c.id, model.checkRows)
            }
        }
        .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, button: false) { await model.load(full: true) }
        .sheet(item: $logTarget, onDismiss: {
            guard let request = fixAfterLog else { return }
            fixAfterLog = nil
            onFix(request)
        }) { c in
            if let api = model.api {
                JobLogSheet(api: api, repo: model.ref.repo, check: c, onFix: CIFailureCollector.isFixable(c) && pr.isOpen ? { log in fixAfterLog = CIFixRequest(focus: c.id, log: log); logTarget = nil } : nil)
            }
        }
    }

    private func subtitle(_ c: CheckContext) -> String {
        var parts: [String] = []
        switch c.outcome {
        case .success: parts.append("Successful")
        case .failure: parts.append("Failed")
        case .pending: parts.append(c.status == "QUEUED" ? "Queued" : "In progress")
        case .neutral: parts.append(c.conclusion == "CANCELLED" ? "Cancelled" : "Neutral")
        case .skipped: parts.append("Skipped")
        }
        if let d = c.duration { parts.append(d) }
        if let desc = c.description, !desc.isEmpty { parts.append(desc) }
        return parts.joined(separator: " · ")
    }
}
