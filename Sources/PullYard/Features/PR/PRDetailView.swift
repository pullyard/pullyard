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
    case approve, close, deleteBranch, disableAutoMerge, rerunFailed
    var id: Int { hashValue }
}

struct PRDetailContent: View {
    @Bindable var model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(AppModel.self) private var app
    @Environment(\.liveFront) private var front
    @State private var showReview = false
    @State private var reviewEvent = "COMMENT"
    @State private var showMerge = false
    @State private var showEdit = false
    @State private var showReviewers = false
    @State private var confirm: PRConfirm?
    @State private var showFix = false
    @State private var ciFix: CIFixRequest?
    @State private var expandedOverride = false
    @State private var showReviewPanel = false
    @AppStorage("pr.header.autoCollapse") private var autoCollapse = true

    private var collapsible: Bool {
        autoCollapse && [PRTab.files, .checks, .commits].contains(model.tab)
    }

    private var headerCollapsed: Bool { collapsible && !expandedOverride }

    var body: some View {
        VStack(spacing: 0) {
            if headerCollapsed {
                CompactPRBar(model: model, pr: pr) { expandedOverride = true }
            } else {
                VStack(spacing: 0) {
                    PRHeaderView(model: model, pr: pr, onMerge: { showMerge = true }, onRequestReview: { showReviewers = true }, onFixChecks: pr.isOpen ? { ciFix = CIFixRequest() } : nil, onRerun: canRerun ? { confirm = .rerunFailed } : nil, onCollapse: collapsible ? { expandedOverride = false } : nil)
                    ReReviewBanner(model: model, pr: pr) { showReviewers = true }
                    ClaudeFixBanner(pr: pr) { showFix = true }
                }
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
        .transaction(value: headerCollapsed) { $0.animation = nil }
        .onChange(of: model.tab) { expandedOverride = false }
        .detailTitle(pr.title, subtitle: "\(model.ref.repo.full) #\(pr.number)")
        .task(id: pr.url) {
            app.noteCanonical(model.ref, url: pr.url)
            QueueStore.shared.markSeen(model.ref)
        }
        .onDisappear { QueueStore.shared.markSeen(model.ref) }
        .focusedSceneValue(\.prActions, front ? actions : nil)
        .panelToolbar(id: "pr-detail") { toolbar }
        .inspector(isPresented: $showReviewPanel) {
            ReviewPanel(model: model, pr: pr) { showReviewPanel = false }
                .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        .sheet(isPresented: $showReview) { ReviewSheet(model: model, pr: pr, initialEvent: reviewEvent) }
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
            Button(confirmButton(c), role: c == .approve || c == .rerunFailed ? nil : .destructive) { perform(c) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var actions: PRActions {
        let failing = pr.checks.contains { $0.outcome == .failure }
        return PRActions(
            ref: model.ref,
            number: pr.number,
            isOpen: pr.isOpen,
            canReview: !pr.viewerDidAuthor,
            canMerge: canMerge,
            hasFailing: failing,
            unviewed: model.unviewedCount,
            writeReview: { reviewEvent = "COMMENT"; showReview = true },
            approve: { confirm = .approve },
            requestChanges: { reviewEvent = "REQUEST_CHANGES"; showReview = true },
            merge: { showMerge = true },
            fixWithAgent: { showFix = true },
            fixChecks: { ciFix = CIFixRequest() },
            rerunFailed: { confirm = .rerunFailed },
            markAllViewed: {
                Task {
                    await model.markAllViewed()
                    app.showToast("Marked all files viewed")
                }
            },
            openInBrowser: { openInBrowser(pr.url) },
            copyLink: { copy(pr.url, "Copied link") },
            copyCheckout: { copy("gh pr checkout \(pr.number) -R \(model.ref.repo.full)", "Copied checkout command") }
        )
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
            TabItem(id: PRTab.checks, title: "Checks", icon: "checklist", badge: checksSummary, badgeColor: checksColor, badgeLabel: checksSpoken),
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
        let more = model.hiddenThreadCount > 0 ? "+" : ""
        return unresolved > 0 || !more.isEmpty ? "\(unresolved)\(more)" : nil
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
        if failed > 0 { return "\(failed) failing" }
        if pending > 0 { return "\(pending) running" }
        return "\(checks.count)"
    }

    private var confirmTitle: String {
        switch confirm {
        case .approve: return model.pending.isEmpty ? "Approve this pull request?" : "Approve and submit \(plural(model.pending.count, "pending comment", "pending comments"))?"
        case .close: return "Close pull request without merging?"
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
        case .close: return "Close pull request"
        case .deleteBranch: return "Delete branch"
        case .disableAutoMerge: return "Disable"
        case .rerunFailed: return "Re-run failed jobs"
        }
    }

    private func perform(_ c: PRConfirm) {
        Task {
            switch c {
            case .approve:
                if await model.submitReview(event: "APPROVE", body: "") {
                    app.showToast("Approved #\(pr.number)", kind: .approved, action: app.nextReviewAction(after: model.ref))
                }
            case .close: await model.simple(Q.closePR)
            case .deleteBranch: await model.deleteBranch()
            case .disableAutoMerge: await model.simple(Q.disableAutoMerge)
            case .rerunFailed: await model.rerunFailed()
            }
        }
    }

    private var canMerge: Bool {
        pr.isOpen && !pr.isDraft && model.canWrite
    }

    private var canRerun: Bool {
        model.canWrite && pr.checks.contains { $0.outcome == .failure && $0.runId != nil }
    }

    private var hasFailingChecks: Bool {
        pr.checks.contains { $0.outcome == .failure }
    }

    private var mergeBlocker: MergeRequirement? {
        model.requirements.first { $0.state == .missing } ?? model.requirements.first { $0.state == .pending }
    }

    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "pr.status", placement: .primaryAction) {
            RefreshPill(updated: model.lastUpdated, refreshing: model.loading || model.busy, error: model.refreshError) {
                Task { await model.load(full: true) }
            }
        }
        if pr.isOpen {
            ToolbarItem(id: "pr.review", placement: .primaryAction) {
                Menu {
                    Button("Write review…") { reviewEvent = "COMMENT"; showReview = true }
                    Button(showReviewPanel ? "Hide Review Panel" : "Review in Side Panel") { showReviewPanel.toggle() }
                    if !pr.viewerDidAuthor {
                        Button("Approve") { confirm = .approve }
                    }
                    Divider()
                    Button("Request review…") { showReviewers = true }
                } label: {
                    Label(model.pending.isEmpty ? "Review" : "Review (\(model.pending.count))", systemImage: "checkmark.bubble")
                } primaryAction: {
                    reviewEvent = "COMMENT"
                    showReview = true
                }
                .labelStyle(.titleAndIcon)
                .help(model.pending.isEmpty ? "Write a review (⇧⌘R)" : "Submit review with \(plural(model.pending.count, "pending comment", "pending comments")) (⇧⌘R)")
            }
            ToolbarItem(id: "pr.reviewPanel", placement: .primaryAction) {
                Button { showReviewPanel.toggle() } label: {
                    Label("Review panel", systemImage: "sidebar.right")
                }
                .help(showReviewPanel ? "Hide the review panel (⌥⌘I)" : "Review next to the diff (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            ToolbarItem(id: "pr.requestReview", placement: .primaryAction, showsByDefault: false) {
                Button { showReviewers = true } label: { Label("Request review", systemImage: "person.crop.circle.badge.plus") }
                    .help("Request or re-request review")
            }
        }
        if pr.isOpen {
            ToolbarItem(id: "pr.fix", placement: .primaryAction) {
                Menu {
                    Button("Review comments…") { showFix = true }
                    Button("Failing checks…") { ciFix = CIFixRequest() }
                        .disabled(!hasFailingChecks)
                    Button("Conflicts…") { model.showResolveConflicts = true }
                        .disabled(!MergeConflicts.applies(pr))
                } label: {
                    Label("Fix with agent", systemImage: "wrench.and.screwdriver")
                } primaryAction: {
                    if hasFailingChecks, pr.reviewThreads.nodes.allSatisfy({ $0.isResolved || $0.isOutdated }) {
                        ciFix = CIFixRequest()
                    } else {
                        showFix = true
                    }
                }
                .labelStyle(.titleAndIcon)
                .help("Start an agent session: review comments, failing checks or conflicts")
            }
        }
        if canMerge {
            ToolbarItem(id: "pr.merge", placement: .primaryAction) {
                MergeToolbarButton(blocker: mergeBlocker) { showMerge = true }
            }
        }
        ToolbarItem(id: "pr.more", placement: .primaryAction) {
            ControlGroup {
                Button { openInBrowser(pr.url) } label: { Label("Open in browser", systemImage: "safari") }
                    .help("Open in browser")
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
        Button("Copy link") { copy(pr.url, "Copied link") }
        Button("Copy short link") { app.copyShortLink(ShortLink.ref(url: pr.url) ?? model.ref) }
        Button("Copy “gh pr checkout \(pr.number)”") { copy("gh pr checkout \(pr.number) -R \(model.ref.repo.full)", "Copied checkout command") }
        Button("Copy branch name") { copy(pr.headRefName, "Copied \(pr.headRefName)") }
        Divider()
        if pr.viewerCanUpdate {
            Button("Edit title and description…") { showEdit = true }
        }
        if pr.isOpen {
            if pr.viewerCanUpdate {
                if pr.isDraft {
                    Button("Ready for review") { Task { if await model.simple(Q.readyForReview) { app.showToast("Marked ready for review") } } }
                } else {
                    Button("Convert to draft") { Task { if await model.simple(Q.convertToDraft) { app.showToast("Converted to draft") } } }
                }
            }
            if MergeConflicts.applies(pr) {
                Button("Resolve conflicts with agent…") { model.showResolveConflicts = true }
            }
            if pr.mergeStateStatus == "BEHIND" || pr.mergeStateStatus == "BLOCKED" || pr.mergeStateStatus == "UNSTABLE" {
                Button("Update branch from \(pr.baseRefName)") { Task { if await model.simple(Q.updateBranch) { app.showToast("Branch updated from \(pr.baseRefName)") } } }
            }
            if pr.autoMergeRequest != nil {
                Button("Disable auto-merge") { confirm = .disableAutoMerge }
            }
            Divider()
            if pr.viewerCanUpdate {
                Button("Close pull request…") { confirm = .close }
            }
        } else if !pr.merged, pr.viewerCanUpdate {
            Button("Reopen pull request") { Task { if await model.simple(Q.reopenPR) { app.showToast("Pull request reopened") } } }
        }
        if !pr.isOpen, pr.headRef != nil, model.canWrite {
            Button("Delete branch \(pr.headRefName)…") { confirm = .deleteBranch }
        }
    }
}

extension PRDetailContent {
    fileprivate func copy(_ value: String, _ message: String) {
        copyToPasteboard(value, announce: false)
        app.showToast(message)
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
        .detailTitle(node.title, subtitle: "\(model.ref.repo.full) #\(node.number)")
    }
}

struct PRHeaderView: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onMerge: () -> Void
    var onRequestReview: () -> Void = {}
    var onFixChecks: (() -> Void)?
    var onRerun: (() -> Void)?
    var onCollapse: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(pr.title).font(.syTitle2.weight(.bold)).textSelection(.enabled)
                Text("#\(pr.number)").font(.syTitle2).foregroundStyle(Color.syDim)
                ShortLinkButton(ref: ShortLink.ref(url: pr.url) ?? model.ref)
                Spacer(minLength: 8)
                AgentRunChip(ref: model.ref)
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: "chevron.up").font(.syIcon(11)).frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.syMuted)
                    .help("Collapse the header")
                    .accessibilityLabel("Collapse header")
                }
            }
            HStack(spacing: 8) {
                StateBadge(state: pr.visualState)
                Avatar(url: pr.author?.avatarUrl, size: 18)
                Text(pr.author?.login ?? "ghost").fontWeight(.semibold)
                BranchChip(name: pr.baseRefName)
                Image(systemName: "arrow.left").font(.syCaption).foregroundStyle(Color.syDim)
                BranchChip(name: pr.headRefName, color: .syViolet)
                DiffStat(additions: pr.additions, deletions: pr.deletions)
                Spacer(minLength: 0)
                Text(Fmt.rel(pr.createdAt)).foregroundStyle(Color.syMuted).help(Fmt.full.string(from: pr.createdAt))
            }
            .font(.syCallout)
            .lineLimit(1)
            if !pr.labels.nodes.isEmpty || !model.reviewers.isEmpty || !pr.assignees.nodes.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
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
            MergeStatusBar(model: model, pr: pr, onMerge: onMerge, onRequestReview: onRequestReview, onFixChecks: onFixChecks, onRerun: onRerun)
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
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            copyToPasteboard(name, announce: false)
            app.showToast("Copied \(name)")
        } label: {
            Text(name)
                .font(.syCaption.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.12)))
                .foregroundStyle(color)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Copy branch name")
        .accessibilityLabel("Branch \(name)")
        .accessibilityHint("Copies the branch name")
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
    var onFixChecks: (() -> Void)?
    var onRerun: (() -> Void)?
    @Environment(AppModel.self) private var app
    @AppStorage("pr.mergeRequirementsExpanded") private var expanded = true
    @State private var showConflicts = false

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
                    if MergeConflicts.applies(pr) {
                        Button(conflictsTitle) { showConflicts = true }
                            .controlSize(.small)
                            .help("Show the conflicting files")
                            .popover(isPresented: $showConflicts, arrowEdge: .bottom) { conflictsPopover }
                    }
                    if !expanded || requirements.isEmpty, pr.mergeStateStatus == "BEHIND", model.canWrite || pr.viewerCanUpdate {
                        Button("Update branch") {
                            Task { if await model.simple(Q.updateBranch) { app.showToast("Branch updated from \(pr.baseRefName)") } }
                        }
                        .controlSize(.small)
                    }
                    if !expanded || requirements.isEmpty, pr.isDraft, pr.viewerCanUpdate {
                        Button("Ready for review") {
                            Task { if await model.simple(Q.readyForReview) { app.showToast("Marked ready for review") } }
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
                    MergeRequirementsList(requirements: requirements, ownership: model.ownership, canPerform: canPerform, perform: perform, agentFix: agentFix, rerun: onRerun)
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
        case .requestReview: return model.canWrite || pr.viewerDidAuthor
        case .updateBranch: return model.canWrite || pr.viewerCanUpdate
        case .readyForReview: return pr.viewerCanUpdate
        case .showConflicts: return !MergeConflicts.applies(pr)
        case .showChecks, .showConversation: return true
        }
    }

    private func agentFix(_ kind: RequirementKind) -> (() -> Void)? {
        switch kind {
        case .conflicts where MergeConflicts.applies(pr): return { model.showResolveConflicts = true }
        case .checks, .optionalChecks: return onFixChecks
        default: return nil
        }
    }

    private var conflictsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conflicts with \(pr.baseRefName)").font(.syHeadline)
            switch model.conflicts {
            case .files(let files)?:
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(files, id: \.self) { file in
                            Label(file, systemImage: "exclamationmark.triangle")
                                .font(.syCallout.monospaced())
                                .foregroundStyle(Color.syText)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(file)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            case .checking?:
                HStack(spacing: 6) {
                    PYLoader(size: 12)
                    Text("Checking which files conflict…").font(.syCallout).foregroundStyle(Color.syMuted)
                }
            case .noClone?:
                Text("Choose a local clone to see which files conflict.").font(.syCallout).foregroundStyle(Color.syMuted)
            case .unavailable(let reason)?:
                Text(reason).font(.syCallout).foregroundStyle(Color.syMuted)
            case nil:
                Text("GitHub reports conflicts with the base branch.").font(.syCallout).foregroundStyle(Color.syMuted)
            }
            HStack {
                Button("Show in conversation") {
                    showConflicts = false
                    model.tab = .conversation
                    model.scrollToBottomToken += 1
                }
                Spacer()
                Button("Resolve with agent…") {
                    showConflicts = false
                    model.showResolveConflicts = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.syAgentFill)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 380)
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
            Task { if await model.simple(Q.updateBranch) { app.showToast("Branch updated from \(pr.baseRefName)") } }
        case .readyForReview:
            Task { if await model.simple(Q.readyForReview) { app.showToast("Marked ready for review") } }
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
                HStack(spacing: 4) {
                    if failed > 0 { StatusChip(text: "\(failed) failing", icon: "xmark.circle.fill", color: .ghRed) }
                    if pending > 0 { StatusChip(text: "\(pending) running", icon: "circle.dashed", color: .syAmberInk) }
                    if ok > 0 || (failed == 0 && pending == 0) { StatusChip(text: "\(ok) passing", icon: "checkmark.circle.fill", color: .ghGreen) }
                }
            }
            .buttonStyle(.plain)
            .help("Checks")
            .accessibilityLabel("Checks")
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

    private var text: String { model.commentDraft }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HTMLView(html: model.html, scrollToBottomToken: model.scrollToBottomToken, onAction: handle, onLink: openLink)
                .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, web: true, button: false) { await model.load(full: true) }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                ComposerBox(text: $model.commentDraft, placeholder: "Comment (Markdown) — ⌘↩ to send", minHeight: 56).frame(height: 64)
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
            if await model.comment(body) { model.commentDraft = "" }
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
    @Environment(AppModel.self) private var app

    private var days: [(title: String, commits: [CommitInfoNode])] {
        let cal = Calendar.current
        var order: [String] = []
        var map: [String: [CommitInfoNode]] = [:]
        for node in pr.allCommits.nodes.reversed() {
            let date = node.commit.committedDate
            let title: String
            if cal.isDateInToday(date) { title = "Today" }
            else if cal.isDateInYesterday(date) { title = "Yesterday" }
            else { title = date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) }
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(node)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        let reviewed = model.lastReviewed?.oid
        List {
            if (pr.allCommits.totalCount ?? 0) > pr.allCommits.nodes.count {
                Label("Showing the latest \(pr.allCommits.nodes.count) of \(pr.allCommits.totalCount ?? 0) commits", systemImage: "clock.arrow.circlepath")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            ForEach(days, id: \.title) { day in
                Section {
                    ForEach(Array(day.commits.enumerated()), id: \.element.commit.oid) { index, node in
                        let c = node.commit
                        if c.oid == reviewed {
                            reviewMarker
                        }
                        NavigationLink(value: Route.commit(model.ref.repo, c.oid)) {
                            CommitTimelineRow(commit: node, first: index == 0, last: index == day.commits.count - 1, tint: index.isMultiple(of: 2) ? .syViolet : .syAccent)
                                .rowAppear(c.oid, model.commitRows)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
                        .contextMenu {
                            Button("Copy SHA") {
                                copyToPasteboard(c.oid, announce: false)
                                app.showToast("Copied \(c.abbreviatedOid)")
                            }
                            Button("Open in browser") { openInBrowser(c.url) }
                        }
                    }
                } header: {
                    Text(day.title)
                        .font(.sy(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(Color.syMuted)
                }
            }
            if (pr.allCommits.totalCount ?? 0) > pr.allCommits.nodes.count {
                Button("Show all \(pr.allCommits.totalCount ?? 0) commits in browser") { openInBrowser(pr.url + "/commits") }
            }
        }
        .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, button: false) { await model.load(full: true) }
    }

    private var reviewMarker: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.syCoral.opacity(0.5)).frame(height: 1)
            Text("Your last review")
                .font(.sy(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Color.syCoralInk)
                .fixedSize()
            Rectangle().fill(Color.syCoral.opacity(0.5)).frame(height: 1)
        }
        .listRowSeparator(.hidden)
        .padding(.vertical, 2)
    }
}

private struct CommitTimelineRow: View {
    let commit: CommitInfoNode
    let first: Bool
    let last: Bool
    let tint: Color
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let c = commit.commit
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(first ? Color.clear : Color.syLineStrong).frame(width: 2)
                    Rectangle().fill(last ? Color.clear : Color.syLineStrong).frame(width: 2)
                }
                Circle()
                    .strokeBorder(tint, lineWidth: 2.5)
                    .background(Circle().fill(Color.syPanel))
                    .frame(width: 12, height: 12)
            }
            .frame(width: 14)
            Avatar(url: c.author?.avatarUrl, size: 24, ring: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.messageHeadline).font(.syBody.weight(.medium)).foregroundStyle(Color.syText).lineLimit(2)
                Text("\(c.author?.user?.login ?? c.author?.name ?? "") · \(Fmt.rel(c.committedDate))")
                    .font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Spacer(minLength: 8)
            CIChip(state: c.statusCheckRollup?.state)
            Button {
                copyToPasteboard(c.oid, announce: false)
                app.showToast("Copied \(c.abbreviatedOid)")
            } label: {
                HStack(spacing: 4) {
                    Text(c.abbreviatedOid).font(.syCaption.monospaced())
                    Image(systemName: "doc.on.doc").font(.syIcon(9)).opacity(hovering ? 1 : 0)
                }
                .foregroundStyle(Color.syMuted)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.syText.opacity(hovering ? 0.07 : 0.04)))
            }
            .buttonStyle(.plain)
            .help("Copy full SHA")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ChecksTab: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onFix: (CIFixRequest) -> Void
    let onRerun: () -> Void
    @State private var logTarget: CheckContext?
    @State private var fixAfterLog: CIFixRequest?
    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        let checks = pr.checks.sorted { ($0.outcome.rawValue, $0.title) < ($1.outcome.rawValue, $1.title) }
        let failedRuns = Set(checks.filter { $0.outcome == .failure }.compactMap(\.runId))
        let groups = Self.groups(checks)
        List {
            if checks.isEmpty {
                Text("No checks for the latest commit").font(.syBody).foregroundStyle(Color.syMuted)
            } else {
                summary(checks, failedRuns: failedRuns)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups, id: \.name) { group in
                Section(isExpanded: binding(for: group)) {
                    ForEach(group.checks) { c in row(c) }
                } header: {
                    groupHeader(group)
                }
            }
            if model.hiddenCheckCount > 0 {
                Button("\(model.hiddenCheckCount) more checks are not shown — open in browser") { openInBrowser(pr.url + "/checks") }
                    .buttonStyle(.link)
                    .font(.syCaption)
            }
        }
        .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false, button: false) { await model.load(full: true) }
        .sheet(item: $logTarget, onDismiss: {
            guard let request = fixAfterLog else { return }
            fixAfterLog = nil
            onFix(request)
        }) { c in
            JobLogSheet(api: model.api, repo: model.ref.repo, check: c, onFix: CIFailureCollector.isFixable(c) && pr.isOpen ? { log in fixAfterLog = CIFixRequest(focus: c.id, log: log); logTarget = nil } : nil)
        }
    }

    struct CheckGroup {
        let name: String
        let checks: [CheckContext]
        var failed: Int { checks.filter { $0.outcome == .failure }.count }
        var running: Int { checks.filter { $0.outcome == .pending }.count }
        var passed: Int { checks.filter { $0.outcome == .success }.count }
        var outcome: CheckOutcome { failed > 0 ? .failure : running > 0 ? .pending : passed > 0 ? .success : .neutral }
    }

    static func groups(_ checks: [CheckContext]) -> [CheckGroup] {
        var order: [String] = []
        var map: [String: [CheckContext]] = [:]
        for c in checks {
            let name = c.workflowName ?? "Other checks"
            if map[name] == nil { order.append(name) }
            map[name, default: []].append(c)
        }
        let groups = order.map { CheckGroup(name: $0, checks: map[$0] ?? []) }
        return groups.sorted { a, b in
            let rank: (CheckGroup) -> Int = { $0.failed > 0 ? 0 : $0.running > 0 ? 1 : 2 }
            return (rank(a), a.name) < (rank(b), b.name)
        }
    }

    private func binding(for group: CheckGroup) -> Binding<Bool> {
        Binding(
            get: { expanded[group.name] ?? (group.failed > 0 || group.running > 0) },
            set: { expanded[group.name] = $0 }
        )
    }

    private func summary(_ checks: [CheckContext], failedRuns: Set<Int>) -> some View {
        let failed = checks.filter { $0.outcome == .failure }.count
        let running = checks.filter { $0.outcome == .pending }.count
        let passed = checks.filter { $0.outcome == .success }.count
        let skipped = checks.count - failed - running - passed
        let required = checks.filter { $0.isRequired == true }
        return HStack(spacing: 6) {
            if failed > 0 { StatusChip(text: "\(failed) failing", icon: "xmark.circle.fill", color: .ghRed) }
            if running > 0 { StatusChip(text: "\(running) running", icon: "circle.dashed", color: .syAmberInk) }
            StatusChip(text: "\(passed) passing", icon: "checkmark.circle.fill", color: .ghGreen)
            if skipped > 0 { StatusChip(text: "\(skipped) skipped", icon: "minus.circle", color: .syMuted) }
            if !required.isEmpty {
                let ok = required.filter { $0.outcome == .success }.count
                Text("Required \(ok)/\(required.count)")
                    .font(.syCaption.weight(.medium))
                    .foregroundStyle(ok == required.count ? Color.ghGreen : Color.syMuted)
                    .padding(.leading, 4)
            }
            Spacer()
            if !failedRuns.isEmpty, model.canWrite {
                Button(action: onRerun) {
                    Label("Re-run failed (\(plural(failedRuns.count, "workflow", "workflows")))", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.busy)
            }
        }
        .padding(.vertical, 4)
    }

    private func groupHeader(_ group: CheckGroup) -> some View {
        HStack(spacing: 8) {
            OutcomeIcon(outcome: group.outcome)
            Text(group.name).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1)
            Text(groupCounts(group)).font(.syCaption).foregroundStyle(Color.syMuted)
            Spacer()
        }
    }

    private func groupCounts(_ group: CheckGroup) -> String {
        var parts: [String] = []
        if group.failed > 0 { parts.append("\(group.failed) failed") }
        if group.running > 0 { parts.append("\(group.running) running") }
        parts.append("\(group.passed)/\(group.checks.count) passed")
        return parts.joined(separator: " · ")
    }

    private func row(_ c: CheckContext) -> some View {
        HStack(spacing: 10) {
            OutcomeIcon(outcome: c.outcome)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(c.title).font(.syBody).lineLimit(1)
                    if c.isRequired == true {
                        Text("Required")
                            .font(.sy(size: 10, weight: .semibold))
                            .foregroundStyle(Color.syMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(Color.syLineStrong))
                    }
                }
                Text(subtitle(c)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
            }
            Spacer()
            if CIFailureCollector.isFixable(c), pr.isOpen {
                Button("Fix with agent") { onFix(CIFixRequest(focus: c.id)) }
                    .controlSize(.small)
                    .tint(Color.syCoralFill)
            }
            if c.isActionsJob, c.outcome != .pending, c.outcome != .skipped {
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

struct MergeToolbarButton: View {
    let blocker: MergeRequirement?
    let action: () -> Void

    var body: some View {
        if let blocker {
            Button(action: action) { Label("Merge", systemImage: "arrow.triangle.merge") }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.syMuted)
                .help(blocker.state == .missing ? "Blocked: \(blocker.title). Open to review merge requirements (⇧⌘M)" : "\(blocker.title) — merge may need to wait (⇧⌘M)")
                .accessibilityHint(blocker.title)
        } else {
            Button(action: action) { Label("Merge", systemImage: "arrow.triangle.merge") }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(Color.syGreenFill)
                .help("Ready to merge (⇧⌘M)")
        }
    }
}

struct AgentRunChip: View {
    let ref: ItemRef
    @Environment(AppModel.self) private var app

    var body: some View {
        if let launch = app.claude.prFixes[ref] ?? app.claude.ciFixes[ref],
           let id = launch.tabID,
           let tab = app.claude.tabs.first(where: { $0.id == id }) {
            let state = tab.state
            Button {
                app.claude.selectedTabID = tab.id
                app.section = .claude
            } label: {
                HStack(spacing: 5) {
                    if state == .working {
                        PYLoader(size: 11, label: "Agent working")
                    } else {
                        Image(systemName: state == .waiting ? "hand.raised.fill" : "checkmark.circle.fill").font(.syIcon(10))
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(label(state, since: launch.at, now: context.date))
                            .lineLimit(1)
                    }
                }
                .font(.sy(size: 11, weight: .semibold))
                .foregroundStyle(Color.syCoralInk)
                .padding(.horizontal, 8)
                .frame(height: TextZoom.shared.size(20))
                .background(Capsule().fill(Color.syCoral.opacity(0.12)))
                .fixedSize()
            }
            .buttonStyle(.plain)
            .help("Open the agent session")
            .accessibilityLabel("Agent session: \(state.title)")
        }
    }

    private func label(_ state: ClaudeTabState, since: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        let age = minutes < 1 ? "just now" : "\(minutes)m"
        switch state {
        case .working: return "Agent running · \(age)"
        case .waiting: return "Agent needs you"
        default: return "Agent session · \(age)"
        }
    }
}

struct CompactPRBar: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onExpand: () -> Void

    var body: some View {
        let failing = pr.checks.filter { $0.outcome == .failure }.count
        let running = pr.checks.filter { $0.outcome == .pending }.count
        let total = model.displayedFiles.count
        let viewed = model.viewedPaths.intersection(model.displayedFiles.map(\.id)).count
        HStack(spacing: 8) {
            Image(systemName: pr.visualState.compactIcon)
                .font(.syIcon(10))
                .foregroundStyle(pr.visualState.color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(pr.visualState.color.opacity(Tint.tile)))
                .help(pr.visualState.title)
            Text("#\(pr.number)").font(.sy(size: 13)).foregroundStyle(Color.syMuted).monospacedDigit()
            Text(pr.title)
                .font(.sy(size: 13, weight: .semibold))
                .foregroundStyle(Color.syText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if failing > 0 {
                Button { model.tab = .checks } label: { StatusChip(text: "\(failing) failing", icon: "xmark.circle.fill", color: .ghRed) }
                    .buttonStyle(.plain)
                    .help("Show checks")
            } else if running > 0 {
                Button { model.tab = .checks } label: { StatusChip(text: "\(running) running", icon: "circle.dashed", color: .syAmberInk) }
                    .buttonStyle(.plain)
                    .help("Show checks")
            }
            if MergeConflicts.applies(pr) {
                Button(action: onExpand) { StatusChip(text: "Conflicts", icon: "exclamationmark.triangle.fill", color: .ghRed) }
                    .buttonStyle(.plain)
                    .help("Show merge requirements")
            }
            if model.filesLoaded, total > 0 {
                StatusChip(text: "Viewed \(viewed)/\(total)", icon: viewed == total ? "checkmark.circle.fill" : "eye", color: viewed == total ? .ghGreen : .syMuted)
            }
            AgentRunChip(ref: model.ref)
            Button(action: onExpand) {
                Image(systemName: "chevron.down").font(.syIcon(11)).frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.syMuted)
            .help("Show the full header")
            .accessibilityLabel("Expand header")
        }
        .padding(.horizontal, 16)
        .frame(height: TextZoom.shared.size(36))
        .accessibilityElement(children: .contain)
    }
}
