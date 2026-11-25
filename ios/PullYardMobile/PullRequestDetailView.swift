import SwiftUI

private enum PRSection: String, CaseIterable, Identifiable {
    case overview = "Overview", conversation = "Conversation", checks = "Checks"
    var id: String { rawValue }
}

private struct ReviewThread: Identifiable {
    let root: PRComment
    let replies: [PRComment]
    var id: Int { root.id }
    var lastDate: Date { replies.last?.createdAt ?? root.createdAt }
}

private enum TimelineItem: Identifiable {
    case review(PRReview)
    case comment(PRComment)
    case thread(ReviewThread)
    case event(TimelineEvent)
    case commits([TimelineEvent])
    case newDivider(Date)

    var id: String {
        switch self {
        case .review(let value): "review-\(value.id)"
        case .comment(let value): "comment-\(value.id)"
        case .thread(let value): "thread-\(value.id)"
        case .event(let value): "event-\(value.id)"
        case .commits(let value): "commits-\(value.first?.id ?? "")"
        case .newDivider: "new-divider"
        }
    }

    var date: Date {
        switch self {
        case .review(let value): value.submittedAt ?? .distantPast
        case .comment(let value): value.createdAt
        case .thread(let value): value.root.createdAt
        case .event(let value): value.date
        case .commits(let value): value.first?.date ?? .distantPast
        case .newDivider(let date): date
        }
    }

    var isActivity: Bool {
        switch self { case .event, .commits, .newDivider: false; default: true }
    }
}

struct ReactAction {
    let handler: (PRComment, ReactionKind) -> Void
}

struct ReactActionKey: EnvironmentKey {
    static let defaultValue: ReactAction? = nil
}

extension EnvironmentValues {
    var pyReact: ReactAction? {
        get { self[ReactActionKey.self] }
        set { self[ReactActionKey.self] = newValue }
    }
}

struct PRDetailView: View {
    let key: PRKey
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var pull: PullRequest?
    @State private var checks: [CheckRun]?
    @State private var reviews: [PRReview] = []
    @State private var comments: [PRComment] = []
    @State private var reviewComments: [PRComment] = []
    @State private var section: PRSection = .overview
    @State private var isLoading = false
    @State private var isLoadingChecks = false
    @State private var loadError: String?
    @State private var composer: ComposerRequest?
    @State private var visibleCount = 30
    @State private var confirmDiscardPending = false
    @State private var markedRead = false
    @State private var expandedThreads: Set<Int> = []
    @State private var successPulse = 0
    @State private var insight: PRInsight?
    @State private var showMerge = false
    @State private var confirmClose = false
    @State private var isWorking = false
    @State private var showResolved: Set<Int> = []
    @State private var events: [TimelineEvent] = []
    @State private var previousVisit: Date?
    @State private var visitRecorded = false
    @State private var expandedCommits: Set<String> = []
    @State private var pendingCount: Int?
    @State private var following = false

    init(key: PRKey, initial: PullRequest? = nil) {
        self.key = key
        _pull = State(initialValue: initial)
    }

    private var canWrite: Bool { insight?.canWrite ?? false }
    private var canManage: Bool { isAuthor || canWrite }

    private var isAuthor: Bool { pull.map(model.isAuthor) ?? false }
    private var pendingReview: PRReview? { reviews.first(where: \.isPending) }
    private var canReview: Bool { guard let pull else { return false }; return pull.isOpen && !pull.isDraft && !isAuthor }
    private var myLatestReview: PRReview? {
        reviews.filter { !$0.isPending && $0.state != "COMMENTED" && $0.user?.isSameAccount(as: model.user) == true }.last
    }
    private var notificationReason: String? {
        model.notifications.first { $0.pullKey == key }?.reason
    }

    var body: some View {
        Group {
            if let pull {
                content(pull)
            } else if let loadError {
                ScrollView {
                    ErrorStateView(title: "Couldn't load \(key.repo) #\(key.number)", message: loadError) { Task { await load() } }
                        .padding(.top, 80)
                }
                .refreshable { await load() }
            } else {
                DetailSkeleton()
            }
        }
        .background(BrandBackdrop())
        .navigationTitle("\(key.repo.split(separator: "/").last.map(String.init) ?? key.repo) #\(key.number)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    if let pull, let insight, canManage {
                        Section {
                            if pull.isOpen && !insight.isDraft && isAuthor {
                                Button { Task { await toggleDraft(true) } } label: { Label("Convert to draft", systemImage: "circle.dashed") }
                            }
                            if pull.isOpen && insight.autoMergeAllowed && canWrite {
                                if insight.autoMergeEnabled {
                                    Button { Task { await setAutoMerge(nil) } } label: { Label("Disable auto-merge", systemImage: "bolt.slash") }
                                } else {
                                    Menu { ForEach(insight.mergeMethods) { method in Button(method.title) { Task { await setAutoMerge(method) } } } } label: { Label("Enable auto-merge", systemImage: "bolt") }
                                }
                            }
                            if pull.isOpen && insight.isBehind {
                                Button { Task { await updateBranch() } } label: { Label("Update branch", systemImage: "arrow.down.circle") }
                            }
                            if !pull.isMerged {
                                Button(role: pull.isOpen ? .destructive : nil) { if pull.isOpen { confirmClose = true } else { Task { await setOpen(true) } } } label: {
                                    Label(pull.isOpen ? "Close pull request" : "Reopen pull request", systemImage: pull.isOpen ? "xmark.circle" : "arrow.uturn.left.circle")
                                }
                            }
                        }
                    }
                    if let pull, let checks, checks.contains(where: \.isPending) || following, LiveActivityManager.isAvailable {
                        Button {
                            Task { await toggleFollow(pull, checks: checks) }
                        } label: {
                            Label(following ? "Stop following checks" : "Follow checks on Lock Screen", systemImage: following ? "bell.slash" : "dot.radiowaves.left.and.right")
                        }
                    }
                    if canReview, myLatestReview != nil {
                        Button { openReview(.approve) } label: { Label("Approve again", systemImage: "checkmark.seal") }
                        Button { openReview(.requestChanges) } label: { Label("Request changes", systemImage: "arrow.uturn.backward") }
                    }
                    if let url = pull?.htmlUrl {
                        Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
                        Button { UIPasteboard.general.url = url; feedback.success("Link copied") } label: { Label("Copy link", systemImage: "link") }
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    RefreshGlyph(isRefreshing: isLoading && pull != nil, symbol: "ellipsis.circle")
                }
                .accessibilityLabel("Pull request actions")
                .disabled(pull == nil)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let pull { actionBar(pull) }
        }
        .task { await load() }
        .sheet(item: $composer) { request in
            ComposerSheet(request: withParticipants(request)) { body in try await submit(request, body: body) }
        }
        .sheet(isPresented: $showMerge) {
            if let pull, let insight {
                MergeSheet(pull: pull, insight: insight) { method, title, message, deleteBranch in
                    try await performMerge(method: method, title: title, message: message, deleteBranch: deleteBranch)
                }
            }
        }
        .confirmationDialog("Close this pull request?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close pull request", role: .destructive) { Task { await setOpen(false) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You can reopen it later.") }
        .confirmationDialog("Discard your pending review?", isPresented: $confirmDiscardPending, titleVisibility: .visible) {
            Button("Discard review", role: .destructive) { Task { await discardPendingReview() } }
            Button("Keep it", role: .cancel) {}
        } message: { Text("Comments you added to this pending review will be deleted.") }
        .sensoryFeedback(.success, trigger: successPulse)
        .userActivity("com.pullyard.pullrequest", isActive: pull != nil) { activity in
            activity.title = pull.map { "\($0.title) · \(key.repo) #\(key.number)" } ?? "\(key.repo) #\(key.number)"
            activity.webpageURL = pull?.htmlUrl ?? URL(string: "https://github.com/\(key.repo)/pull/\(key.number)")
            activity.userInfo = ["repo": key.repo, "number": key.number]
            activity.isEligibleForHandoff = true
        }
        .task(id: checks.map(ChecksSummary.init)) {
            following = LiveActivityManager.isFollowing(key)
            guard case .running = ChecksSummary(checks), let current = pull else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await loadChecks(current)
                if case .running = ChecksSummary(checks) { continue }
                return
            }
        }
        .environment(\.pyReact, ReactAction { comment, kind in react(comment, kind) })
        .feedbackChrome { Task { await load() } }
    }

    private func content(_ pr: PullRequest) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    hero(pr).padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            switch section {
                            case .overview: overview(pr)
                            case .conversation: conversation
                            case .checks: checksContent(pr)
                            }
                        }
                        .padding(16)
                        Color.clear.frame(height: 1).id("bottom")
                    } header: {
                        SectionSwitcher(selection: $section, title: sectionTitle)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(
                                LinearGradient(colors: [MobileTheme.canvas.opacity(0.9), MobileTheme.canvas.opacity(0)], startPoint: .top, endPoint: .bottom)
                                    .ignoresSafeArea()
                            )
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
            .pullToRefreshLogo(isRefreshing: isLoading)
            .onChange(of: section) { _, value in
                guard value == .conversation else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func sectionTitle(_ section: PRSection) -> String {
        switch section {
        case .overview: return L(section.rawValue)
        case .conversation:
            let count = timeline.count
            if let unresolved = insight?.unresolvedCount, unresolved > 0 { return "\(L(section.rawValue)) · \(unresolved)" }
            return count > 0 ? "\(L(section.rawValue)) \(count)" : L(section.rawValue)
        case .checks:
            if case let .failing(count) = ChecksSummary(checks) { return "\(L(section.rawValue)) ✕\(count)" }
            return L(section.rawValue)
        }
    }

    @ViewBuilder private func hero(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let reason = notificationReason {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                    Text("From Inbox")
                    ReasonChip(reason: reason)
                }
                .mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted)
            }
            HStack(spacing: 7) {
                PRStatePill(state: pr.displayState)
                if pr.isOpen && pr.mergeable == false { ConflictPill() }
                if let review = pr.reviewState, review != .reviewRequired { ReviewChip(decision: review) }
                Spacer()
                RelativeTime(date: pr.updatedAt, prefix: "Updated").mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            Text(pr.title).mobileFont(size: 24, weight: .regular, design: .serif).tracking(-0.3).foregroundStyle(MobileTheme.ink).textSelection(.enabled)
            HStack(spacing: 8) {
                AvatarView(url: pr.user?.avatarUrl, size: 24, fallback: pr.user?.login)
                Text(pr.user?.login ?? "Contributor").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink)
                Text(isAuthor ? "· your pull request" : "wants to merge").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
            }
            BranchCard(head: pr.head.ref, base: pr.base.ref)
            if let pendingReview { pendingReviewCard(pendingReview) }
        }
    }

    @ViewBuilder private func overview(_ pr: PullRequest) -> some View {
        if pr.isOpen, let insight {
            MergeReadinessCard(insight: insight, checks: ChecksSummary(checks)) {
                withAnimation(.snappy) { section = .checks }
            } openConversation: {
                withAnimation(.snappy) { section = .conversation }
            }
        } else {
            Button { withAnimation(.snappy) { section = .checks } } label: { ChecksSummaryCard(checks: checks) }
                .buttonStyle(.pyPlain)
        }
        if let body = pr.body, !MarkdownParser.blocks(body).isEmpty {
            MarkdownView(markdown: body, collapsible: true).pyCard()
        } else {
            Text("No description provided.").mobileFont(size: 15).foregroundStyle(MobileTheme.muted).pyCard()
        }
        HStack(spacing: 10) {
            MetricCard(value: pr.additions.map { "+\($0)" } ?? "—", label: "added", color: MobileTheme.green)
            MetricCard(value: pr.deletions.map { "−\($0)" } ?? "—", label: "removed", color: MobileTheme.red)
            NavigationLink(value: Route.files(key)) {
                MetricCard(value: pr.changedFiles.map(String.init) ?? "—", label: "files ›", color: MobileTheme.accent)
            }
            .buttonStyle(.pyPlain)
        }
        NavigationLink(value: Route.files(key)) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(MobileTheme.accent)
                Text("Review changed files").mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                Spacer()
                Text("\(pr.changedFiles ?? 0)").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                Image(systemName: "chevron.right").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
            }
            .padding(16)
            .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous), interactive: true, fallback: MobileTheme.card)
        }
        .buttonStyle(.pyPlain)
        if let insight {
            ReviewersCard(insight: insight, me: model.user, canRerequest: isAuthor && pr.isOpen) { login in
                Task { await rerequest(login) }
            }
            MetadataCard(insight: insight)
        } else if let reviewers = pr.requestedReviewers, !reviewers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionEyebrow("Review requested")
                ForEach(reviewers, id: \.login) { reviewer in
                    HStack(spacing: 9) {
                        AvatarView(url: reviewer.avatarUrl, size: 26, fallback: reviewer.login)
                        Text(reviewer.login).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.ink)
                        if reviewer.isSameAccount(as: model.user) { Text("you").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.coral) }
                    }
                }
            }
            .pyCard()
        }
    }

    private func pendingReviewCard(_ review: PRReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(pendingCount.map { "Your pending review · \($0) comment\($0 == 1 ? "" : "s")" } ?? "You have an unfinished review", systemImage: "pencil.and.list.clipboard").mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.amberInk)
            Text("Only you can see these comments until you submit the review.").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
            HStack(spacing: 12) {
                NavigationLink(value: Route.finishReview(key)) {
                    Text("Finish review").mobileFont(size: 14, weight: .semibold).padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .contentShape(Capsule())
                        .pyGlassCapsule(tint: MobileTheme.greenFill, interactive: true, fallback: MobileTheme.greenFill)
                }
                .buttonStyle(.pyPlain)
                pendingSubmitMenu(review) {
                    Text("Submit review…").mobileFont(size: 14, weight: .semibold).padding(.horizontal, 14).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .contentShape(Capsule())
                        .pyGlassCapsule(tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
                }
                Button("Discard", role: .destructive) { confirmDiscardPending = true }.mobileFont(size: 14, weight: .semibold)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileTheme.amber.opacity(0.13), in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous))
    }

    private func pendingSubmitMenu<Label: View>(_ review: PRReview, @ViewBuilder label: () -> Label) -> some View {
        Menu {
            Button("Comment") { openPendingSubmit(review, .comment) }
            if !isAuthor {
                Button("Approve") { openPendingSubmit(review, .approve) }
                Button("Request changes") { openPendingSubmit(review, .requestChanges) }
            }
        } label: { label() }
    }

    @ViewBuilder private func actionBar(_ pr: PullRequest) -> some View {
        PYGlassGroup(spacing: 10) {
        HStack(spacing: 10) {
            if let pendingReview {
                pendingSubmitMenu(pendingReview) {
                    ActionLabel(title: "Submit review…", symbol: "paperplane.fill", fill: MobileTheme.accentFill)
                }
                commentButton(compact: true)
            } else if pr.isOpen, let insight, insight.isDraft, canManage {
                Button { Task { await toggleDraft(false) } } label: { ActionLabel(title: "Ready for review", symbol: "eye", fill: MobileTheme.accentFill) }
                    .buttonStyle(.pyPlain).disabled(isWorking)
                commentButton(compact: true)
            } else if canReview && !(myLatestReview?.state == "APPROVED" && canWrite) {
                if let mine = myLatestReview, mine.state == "APPROVED" {
                    Label("You approved", systemImage: "checkmark.seal.fill")
                        .mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.green)
                        .symbolEffect(.bounce, value: successPulse)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .pyGlass(in: RoundedRectangle(cornerRadius: 23, style: .continuous), tint: MobileTheme.green.opacity(0.15), fallback: MobileTheme.green.opacity(0.1))
                    Menu {
                        Button("Approve again") { openReview(.approve) }
                        Button("Request changes") { openReview(.requestChanges) }
                    } label: {
                        ActionLabel(title: "Review again", symbol: "arrow.triangle.2.circlepath", fill: nil)
                    }
                } else {
                    Button { openReview(.approve) } label: { ActionLabel(title: "Approve", symbol: "checkmark", fill: MobileTheme.greenFill) }
                        .buttonStyle(.pyPlain)
                    Button { openReview(.requestChanges) } label: { ActionLabel(title: "Changes", symbol: "arrow.uturn.backward", fill: nil, outline: MobileTheme.coral) }
                        .buttonStyle(.pyPlain)
                }
                commentButton(compact: true)
            } else if pr.isOpen, let insight, canWrite {
                mergeButton(insight)
                commentButton(compact: true)
            } else {
                commentButton(compact: false)
            }
        }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
        .background {
            if !GlassSupport.isAvailable {
                Rectangle().fill(.bar).overlay(alignment: .top) { Divider().overlay(MobileTheme.line) }.ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private func mergeButton(_ insight: PRInsight) -> some View {
        if insight.hasConflicts {
            ActionLabel(title: "Conflicts", symbol: "exclamationmark.triangle", fill: nil, outline: MobileTheme.red).opacity(0.8)
        } else if insight.isBehind {
            Button { Task { await updateBranch() } } label: { ActionLabel(title: "Update branch", symbol: "arrow.down.circle", fill: MobileTheme.accentFill) }
                .buttonStyle(.pyPlain).disabled(isWorking)
        } else if insight.isReadyToMerge {
            Button { showMerge = true } label: { ActionLabel(title: "Merge", symbol: "arrow.triangle.merge", fill: MobileTheme.violetFill) }
                .buttonStyle(.pyPlain)
        } else if insight.autoMergeAllowed && !insight.autoMergeEnabled {
            Menu { ForEach(insight.mergeMethods) { method in Button(method.title) { Task { await setAutoMerge(method) } } } } label: {
                ActionLabel(title: "Auto-merge", symbol: "bolt.fill", fill: MobileTheme.violetFill)
            }
        } else if insight.autoMergeEnabled {
            Button { Task { await setAutoMerge(nil) } } label: { ActionLabel(title: "Auto-merge on", symbol: "bolt.fill", fill: nil, outline: MobileTheme.violet) }
                .buttonStyle(.pyPlain)
        } else {
            ActionLabel(title: "Merge blocked", symbol: "lock", fill: nil, outline: MobileTheme.amber).opacity(0.8)
        }
    }

    private func commentButton(compact: Bool) -> some View {
        Button { openComment() } label: {
            if compact {
                Image(systemName: "text.bubble").mobileFont(size: 18, weight: .semibold)
                    .frame(width: 50, height: 46)
                    .contentShape(Circle())
                    .pyGlass(in: Capsule(), interactive: true, fallback: MobileTheme.card)
                    .foregroundStyle(MobileTheme.accent)
            } else {
                ActionLabel(title: "Comment", symbol: "text.bubble", fill: MobileTheme.accentFill)
            }
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel("Comment")
    }

    private var conversation: some View {
        let items = timeline
        return VStack(alignment: .leading, spacing: 12) {
            if items.count > visibleCount {
                Button { withAnimation(.snappy) { visibleCount += 30 } } label: {
                    Label("Show \(min(30, items.count - visibleCount)) earlier", systemImage: "arrow.up").mobileFont(size: 14, weight: .semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            ForEach(items.suffix(visibleCount)) { item in
                switch item {
                case .newDivider:
                    HStack(spacing: 8) {
                        Rectangle().fill(MobileTheme.coral).frame(height: 1.5)
                        Text("New since your last visit").mobileFont(size: 12, weight: .bold).foregroundStyle(MobileTheme.coral).fixedSize()
                        Rectangle().fill(MobileTheme.coral).frame(height: 1.5)
                    }
                    .padding(.vertical, 4)
                    .accessibilityAddTraits(.isHeader)
                case .event(let event):
                    EventRow(event: event)
                case .commits(let commits):
                    CommitsRow(commits: commits, expanded: expandedCommits.contains(commits.first?.id ?? "")) {
                        withAnimation(.snappy) { _ = expandedCommits.insert(commits.first?.id ?? "") }
                    }
                case .review(let review):
                    ReviewCard(review: review)
                case .comment(let comment):
                    CommentCard(comment: comment, isMine: comment.user?.isSameAccount(as: model.user) == true, actionTitle: "Quote reply") {
                        openComment(initialText: quoted(comment))
                    } quote: { openComment(initialText: quoted(comment)) }
                case .thread(let thread):
                    ThreadCard(
                        thread: thread,
                        me: model.user,
                        expanded: expandedThreads.contains(thread.id),
                        state: insight?.thread(forRoot: thread.root.id),
                        showResolved: showResolved.contains(thread.id),
                        canResolve: canManage || canReview,
                        reveal: { showResolved.insert(thread.id) },
                        toggleResolved: { state in Task { await toggleResolved(state) } },
                        expand: { expandedThreads.insert(thread.id) },
                        reply: { composer = ComposerRequest(title: "Reply to thread", mode: .reply(thread.root.id), draft: DraftKey(pull: key, kind: .reply(thread.root.id)), context: thread.replies.last ?? thread.root) }
                    )
                }
            }
            if items.isEmpty && !isLoading {
                PYEmptyState(title: "Start the conversation", message: "There are no comments or reviews yet.") {
                    Button("Write a comment") { openComment() }.buttonStyle(.borderedProminent).tint(MobileTheme.accentFill)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private var timeline: [TimelineItem] {
        _ = insight
        let visibleReviews = reviews.filter { !$0.isPending && !($0.state == "COMMENTED" && ($0.body ?? "").isEmpty) }
        let grouped = Dictionary(grouping: reviewComments, by: \.threadRootId)
        let threads = grouped.compactMap { rootID, items -> ReviewThread? in
            let sorted = items.sorted { $0.createdAt < $1.createdAt }
            guard let root = sorted.first(where: { $0.id == rootID }) ?? sorted.first else { return nil }
            return ReviewThread(root: root, replies: sorted.filter { $0.id != root.id })
        }
        let sorted = (visibleReviews.map(TimelineItem.review) + comments.map(TimelineItem.comment) + threads.map(TimelineItem.thread) + events.map(TimelineItem.event))
            .sorted { $0.date < $1.date }
        var result: [TimelineItem] = []
        var pendingCommits: [TimelineEvent] = []
        func flushCommits() {
            if pendingCommits.count == 1 { result.append(.event(pendingCommits[0])) }
            else if !pendingCommits.isEmpty { result.append(.commits(pendingCommits)) }
            pendingCommits = []
        }
        var dividerPlaced = false
        for item in sorted {
            if !dividerPlaced, let previousVisit, item.date > previousVisit {
                flushCommits()
                result.append(.newDivider(previousVisit))
                dividerPlaced = true
            }
            if case let .event(event) = item, event.kind == .commit {
                pendingCommits.append(event)
            } else {
                flushCommits()
                result.append(item)
            }
        }
        flushCommits()
        if dividerPlaced, result.last.map({ if case .newDivider = $0 { return true }; return false }) == true { result.removeLast() }
        return result
    }

    private func react(_ comment: PRComment, _ kind: ReactionKind) {
        func bump(_ list: inout [PRComment]) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == comment.id }) else { return false }
            var rollup = list[index].reactions ?? ReactionRollup()
            rollup.increment(kind)
            list[index].reactions = rollup
            return true
        }
        let isReview = comment.path != nil
        let previousComments = comments
        let previousReviewComments = reviewComments
        withAnimation(.snappy) {
            if isReview { _ = bump(&reviewComments) } else { _ = bump(&comments) }
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do { try await model.addReaction(key, commentID: comment.id, reviewComment: isReview, content: kind) }
            catch {
                comments = previousComments
                reviewComments = previousReviewComments
                feedback.error(error, key: "reaction")
            }
        }
    }

    @ViewBuilder private func checksContent(_ pr: PullRequest) -> some View {
        ChecksSummaryCard(checks: checks)
        if let checks {
            if checks.isEmpty {
                PYEmptyState(title: "No checks reported", message: "GitHub has no check runs or statuses for the latest commit.")
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                if checks.contains(where: \.isFailure) {
                    Button { Task { await rerunFailed(checks) } } label: {
                        Label("Re-run failed checks", systemImage: "arrow.clockwise.circle.fill").mobileFont(size: 15, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .pyGlassButton(prominent: true, tint: MobileTheme.accentFill)
                    .disabled(isWorking)
                }
                checkGroup("Failing", checks.filter(\.isFailure), expanded: true)
                checkGroup("Running", checks.filter(\.isPending), expanded: true)
                checkGroup("Passed", checks.filter(\.isSuccess), expanded: checks.allSatisfy { $0.isSuccess || $0.isSkipped })
                checkGroup("Skipped", checks.filter(\.isSkipped), expanded: false)
            }
        } else if pr.head.sha.isEmpty || isLoadingChecks || isLoading {
            PullYardLoader(title: "Loading checks…", size: 56).frame(maxWidth: .infinity).padding(.vertical, 24)
        } else {
            ErrorStateView(title: "Checks unavailable", message: "GitHub didn't return checks for this commit.") { Task { await loadChecks(pr) } }
        }
        HStack {
            Link(destination: pr.htmlUrl.appendingPathComponent("checks")) { Label("Full status on GitHub", systemImage: "arrow.up.right") }
            Spacer()
            Button { Task { await loadChecks(pr) } } label: {
                if isLoadingChecks { PullYardLoader(size: 26) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(isLoadingChecks)
        }
        .mobileFont(size: 14, weight: .semibold)
    }

    @ViewBuilder private func checkGroup(_ title: String, _ items: [CheckRun], expanded: Bool) -> some View {
        if !items.isEmpty {
            CheckGroupView(title: title, items: items, initiallyExpanded: expanded)
        }
    }

    private func quoted(_ comment: PRComment) -> String {
        let lines = comment.body.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).map { "> \($0)" }.joined(separator: "\n")
        return "\(lines)\n\n@\(comment.user?.login ?? "") "
    }

    private func withParticipants(_ request: ComposerRequest) -> ComposerRequest {
        var copy = request
        var logins: [String] = []
        let candidates = [pull?.user?.login] + reviews.map(\.user?.login) + comments.map(\.user?.login) + reviewComments.map(\.user?.login) + (insight?.reviewers.map(\.login) ?? [])
        for login in candidates.compactMap({ $0 }) where !logins.contains(login) && !(GitHubUser(login: login).isSameAccount(as: model.user)) {
            logins.append(login)
        }
        copy.participants = logins
        return copy
    }

    private func openComment(initialText: String? = nil) {
        composer = ComposerRequest(title: "Add a comment", mode: .comment, draft: DraftKey(pull: key, kind: .comment), initialText: initialText)
    }

    private func openReview(_ event: ReviewEvent) {
        if let pendingReview { openPendingSubmit(pendingReview, event); return }
        composer = ComposerRequest(title: event == .approve ? "Approve" : "Request changes", mode: .review(event), draft: DraftKey(pull: key, kind: .review(event)), summary: pull.map(summaryLine))
    }

    private func openPendingSubmit(_ review: PRReview, _ event: ReviewEvent) {
        composer = ComposerRequest(title: "Submit review · \(event.title)", mode: .pendingSubmit(review.id, event), draft: DraftKey(pull: key, kind: .pendingReview(review.id)), summary: pull.map(summaryLine))
    }

    private func summaryLine(_ pr: PullRequest) -> ComposerRequest.Summary {
        ComposerRequest.Summary(title: pr.title, subtitle: "\(key.repo) #\(key.number)", checks: ChecksSummary(checks), files: pr.changedFiles)
    }

    private func load() async {
        guard !isLoading else { return }
        if pull == nil || reviews.isEmpty, let cached = model.cachedDetail(key) {
            if pull == nil { pull = cached.pull }
            if reviews.isEmpty { reviews = cached.reviews }
            if comments.isEmpty { comments = cached.comments }
            if reviewComments.isEmpty { reviewComments = cached.reviewComments }
            if checks == nil { checks = cached.checks }
            if insight == nil { insight = cached.insight }
        }
        isLoading = true
        defer { isLoading = false }
        let key = key
        let model = model
        let insightTask = Task { await Self.capture { try await model.insight(key) } }
        let prTask = Task { await Self.capture { try await model.pullRequest(key) } }
        let reviewsTask = Task { await Self.capture { try await model.reviews(key) } }
        let commentsTask = Task { await Self.capture { try await model.comments(key) } }
        let reviewCommentsTask = Task { await Self.capture { try await model.reviewComments(key) } }
        let eventsTask = Task { await Self.capture { try await model.timeline(key) } }
        if !visitRecorded {
            visitRecorded = true
            previousVisit = VisitStore.lastVisit(key)
            VisitStore.markVisited(key)
        }
        switch await prTask.value {
        case let .success(value):
            withAnimation(.snappy) { pull = value }
            loadError = nil
        case let .failure(error):
            if error.isCancellation { return }
            if pull == nil { loadError = error.localizedDescription } else { feedback.error(error, key: "pr-\(key.id)") }
        }
        var partialFailure: Error?
        switch await reviewsTask.value { case let .success(value): reviews = value; case let .failure(error): partialFailure = error }
        switch await commentsTask.value { case let .success(value): comments = value; case let .failure(error): partialFailure = error }
        switch await reviewCommentsTask.value { case let .success(value): reviewComments = value; case let .failure(error): partialFailure = error }
        if let partialFailure, pull != nil { feedback.error(partialFailure, key: "conversation-\(key.id)") }
        if case let .success(value) = await insightTask.value { withAnimation(.snappy) { insight = value } }
        if case let .success(value) = await eventsTask.value { events = value }
        if let pending = reviews.first(where: \.isPending) { pendingCount = try? await model.pendingCommentCount(key, reviewID: pending.id) } else { pendingCount = nil }
        guard let current = pull else { return }
        if !markedRead { markedRead = true; await model.markNotificationsRead(for: key) }
        await loadChecks(current)
        model.storeDetail(PRDetailSnapshot(pull: current, reviews: reviews, comments: comments, reviewComments: reviewComments, checks: checks, insight: insight, savedAt: .now), for: key)
        if current.isOpen && current.mergeable == nil { await recheckMergeable() }
    }

    private func recheckMergeable() async {
        for _ in 0..<2 {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let value = try? await model.pullRequest(key) else { return }
            pull = value
            if value.mergeable != nil { return }
        }
    }

    private func loadChecks(_ pr: PullRequest) async {
        guard !pr.head.sha.isEmpty else { return }
        isLoadingChecks = true
        defer { isLoadingChecks = false }
        do {
            let value = try await model.checks(key, sha: pr.head.sha)
            withAnimation(.snappy) { checks = value }
            await LiveActivityManager.update(key, checks: value)
            following = LiveActivityManager.isFollowing(key)
        } catch { feedback.error(error, key: "checks-\(key.id)") }
    }

    private func submit(_ request: ComposerRequest, body: String) async throws {
        switch request.mode {
        case .comment:
            try await model.addComment(key, body: body)
            feedback.success("Comment posted")
        case let .reply(commentID):
            try await model.reply(key, commentID: commentID, body: body)
            feedback.success("Reply posted")
        case let .review(event), let .pendingSubmit(_, event):
            if case let .pendingSubmit(reviewID, _) = request.mode {
                try await model.submitPendingReview(key, reviewID: reviewID, event: event, body: body)
            } else {
                try await model.submitReview(key, event: event, body: body)
            }
            successPulse += 1
            if event != .comment { model.noteReviewed(key) }
            let title = event == .approve ? "Approved · \(key.repo.split(separator: "/").last ?? "")#\(key.number)" : event == .requestChanges ? "Changes requested" : "Review submitted"
            if event != .comment, let next = model.nextInQueue(after: key) {
                feedback.info(title, key: "reviewed-\(key.id)", actionTitle: "Next ›") { router.replaceTop(with: .pull(next), in: model.selectedTab) }
            } else {
                feedback.success(title)
            }
            model.refreshAll()
        case .lineComment:
            break
        }
        Task { await load() }
    }

    private func performMerge(method: MergeMethod, title: String?, message: String?, deleteBranch: Bool) async throws {
        guard let pull, let insight else { return }
        try await model.merge(key, method: method, title: title, message: message, sha: insight.headSHA)
        successPulse += 1
        if deleteBranch {
            do { try await model.deleteBranch(repo: key.repo, branch: insight.headRefName) }
            catch { feedback.error(error, key: "delete-branch") }
        }
        feedback.success("Merged \(key.repo.split(separator: "/").last ?? "")#\(pull.number)\(deleteBranch ? " · branch deleted" : "")")
        model.refreshAll()
        Task { await load() }
    }

    private func runAction(_ key: String, success: String, _ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            successPulse += 1
            feedback.success(success)
            await load()
        } catch {
            feedback.error(error, key: key)
        }
    }

    private func toggleDraft(_ draft: Bool) async {
        guard let id = insight?.nodeID else { return }
        await runAction("draft", success: draft ? "Converted to draft" : "Ready for review") { try await model.setDraft(pullID: id, draft: draft) }
    }

    private func setAutoMerge(_ method: MergeMethod?) async {
        guard let id = insight?.nodeID else { return }
        await runAction("automerge", success: method == nil ? "Auto-merge disabled" : "Auto-merge enabled") { try await model.setAutoMerge(pullID: id, method: method) }
    }

    private func updateBranch() async {
        guard let sha = insight?.headSHA else { return }
        await runAction("update-branch", success: "Branch update started") { try await model.updateBranch(key, expectedHeadSHA: sha) }
    }

    private func setOpen(_ open: Bool) async {
        await runAction("state", success: open ? "Reopened" : "Closed") { try await model.setState(key, open: open) }
        model.refreshAll()
    }

    private func rerequest(_ login: String) async {
        await runAction("rerequest", success: "Review re-requested from @\(login)") { try await model.requestReviewers(key, logins: [login]) }
    }

    private func toggleResolved(_ state: ThreadState) async {
        guard var current = insight, let index = current.threads.firstIndex(where: { $0.id == state.id }) else { return }
        current.threads[index].isResolved.toggle()
        withAnimation(.snappy) { insight = current }
        do {
            try await model.setThreadResolved(threadID: state.id, resolved: !state.isResolved)
            feedback.success(state.isResolved ? "Conversation reopened" : "Conversation resolved")
        } catch {
            current.threads[index].isResolved = state.isResolved
            insight = current
            feedback.error(error, key: "resolve")
        }
    }

    private func rerunFailed(_ checks: [CheckRun]) async {
        let failed = checks.filter(\.isFailure)
        let runIDs = Set(failed.compactMap { ActionsRun.runID(from: $0.htmlUrl) })
        let others = failed.filter { ActionsRun.runID(from: $0.htmlUrl) == nil && $0.id > 0 }
        await runAction("rerun", success: "Re-running \(failed.count) failed check\(failed.count == 1 ? "" : "s")") {
            for id in runIDs { try await model.rerunFailedJobs(repo: key.repo, runID: id) }
            for check in others { try await model.rerequestCheckRun(repo: key.repo, checkRunID: check.id) }
        }
    }

    private func toggleFollow(_ pull: PullRequest, checks: [CheckRun]) async {
        if following {
            await LiveActivityManager.stop(key)
            following = false
            feedback.info("Stopped following checks", key: "follow")
        } else {
            do {
                try LiveActivityManager.start(key, title: pull.title, checks: checks)
                following = true
                feedback.success("Following checks on your Lock Screen", key: "follow")
            } catch {
                feedback.error(error, key: "follow")
            }
        }
    }

    private func discardPendingReview() async {
        guard let pendingReview else { return }
        do {
            try await model.deletePendingReview(key, reviewID: pendingReview.id)
            DraftStore.shared.clear(DraftKey(pull: key, kind: .pendingReview(pendingReview.id)))
            feedback.success("Pending review discarded")
            await load()
        } catch {
            feedback.error(error, key: "discard-\(key.id)")
        }
    }

    private static func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}

private struct ActionLabel: View {
    let title: String
    let symbol: String
    let fill: Color?
    var outline: Color? = nil

    var body: some View {
        Label(L(title), systemImage: symbol)
            .mobileFont(size: 15, weight: .semibold)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(fill == nil ? (outline ?? MobileTheme.ink) : .white)
            .contentShape(Capsule())
            .pyGlass(in: Capsule(), tint: fill ?? outline?.opacity(0.14), interactive: true, fallback: fill ?? MobileTheme.card)
            .overlay(Capsule().stroke(fill == nil && !GlassSupport.isAvailable ? (outline?.opacity(0.6) ?? MobileTheme.line) : .clear, lineWidth: 1.2))
    }
}

private struct ChecksSummaryCard: View {
    let checks: [CheckRun]?

    var body: some View {
        let summary = ChecksSummary(checks)
        let all = checks ?? []
        let failing = all.filter(\.isFailure).count
        let running = all.filter(\.isPending).count
        let passed = all.filter(\.isSuccess).count
        let skipped = all.filter(\.isSkipped).count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(summary.title, systemImage: summary.symbol)
                    .foregroundStyle(color(summary))
                    .symbolEffect(.pulse, isActive: running > 0 && failing == 0)
                Spacer()
                Image(systemName: "chevron.right").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
            }
            .mobileFont(size: 15, weight: .semibold)
            if !all.isEmpty {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        segment(failing, total: all.count, width: geo.size.width, color: MobileTheme.red)
                        segment(running, total: all.count, width: geo.size.width, color: MobileTheme.amber)
                        segment(passed, total: all.count, width: geo.size.width, color: MobileTheme.green)
                        segment(skipped, total: all.count, width: geo.size.width, color: MobileTheme.slate.opacity(0.5))
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
                HStack(spacing: 12) {
                    if failing > 0 { Text("\(failing) failing").foregroundStyle(MobileTheme.red) }
                    if running > 0 { Text("\(running) running").foregroundStyle(MobileTheme.amber) }
                    if passed > 0 { Text("\(passed) passed").foregroundStyle(MobileTheme.green) }
                    if skipped > 0 { Text("\(skipped) skipped").foregroundStyle(MobileTheme.muted) }
                }
                .mobileFont(size: 12, weight: .medium)
            }
        }
        .pyCard()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func segment(_ count: Int, total: Int, width: CGFloat, color: Color) -> some View {
        if count > 0 {
            Rectangle().fill(color).frame(width: max(4, width * CGFloat(count) / CGFloat(max(total, 1)) - 2))
        }
    }

    private func color(_ summary: ChecksSummary) -> Color {
        switch summary {
        case .failing: MobileTheme.red
        case .running: MobileTheme.amber
        case .passed: MobileTheme.green
        case .none, .notLoaded: MobileTheme.ink
        }
    }
}

private struct CheckGroupView: View {
    let title: String
    let items: [CheckRun]
    @State private var expanded: Bool

    init(title: String, items: [CheckRun], initiallyExpanded: Bool) {
        self.title = title
        self.items = items
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack {
                    SectionEyebrow("\(L(title)) · \(items.count)")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 0 : -90)).foregroundStyle(MobileTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pyPlain)
            if expanded {
                ForEach(items) { CheckRow(check: $0) }
            }
        }
    }
}

struct ComposerRequest: Identifiable {
    enum Mode {
        case comment
        case review(ReviewEvent)
        case reply(Int)
        case pendingSubmit(Int, ReviewEvent)
        case lineComment(path: String, line: Int, side: String)
    }
    struct Summary {
        let title: String
        let subtitle: String
        let checks: ChecksSummary
        let files: Int?
    }
    let id = UUID()
    let title: String
    let mode: Mode
    let draft: DraftKey
    var initialText: String? = nil
    var context: PRComment? = nil
    var summary: Summary? = nil
    var participants: [String] = []
    var alternateTitle: String? = nil

    var event: ReviewEvent? {
        switch mode {
        case let .review(event), let .pendingSubmit(_, event): event
        case .comment, .reply, .lineComment: nil
        }
    }
    var isApprove: Bool { event == .approve }
    var requiresText: Bool { event != .approve && !isPendingComment }
    private var isPendingComment: Bool { if case .pendingSubmit(_, .comment) = mode { return true }; return false }
    var sendTitle: String {
        switch mode {
        case .comment: "Comment"
        case .reply: "Reply"
        case .lineComment: "Add to review"
        case let .review(event), let .pendingSubmit(_, event): event.title
        }
    }
    var guidance: String {
        if event == .approve { return "Leave a note with your approval, or send it without one." }
        if event == .requestChanges { return "Tell the author what needs to change before this is ready." }
        if isPendingComment { return "Add an optional summary to your review." }
        return "Markdown is supported. Your draft is saved automatically."
    }
}

struct ComposerSheet: View {
    let request: ComposerRequest
    let send: (String) async throws -> Void
    var alternate: ((String) async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var confirmClose = false
    @State private var loaded = false
    @State private var showNote = false
    @State private var preview = false
    @State private var selectionOffset: Int?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !isSending && (!request.requiresText || !trimmed.isEmpty) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let errorMessage { errorBanner(errorMessage) }
                    if let summary = request.summary { summaryStrip(summary) }
                    if let context = request.context { contextQuote(context) }
                    if request.isApprove && !showNote {
                        Button { withAnimation(.snappy) { showNote = true; focused = true } } label: {
                            Label("Add a note", systemImage: "plus.bubble").mobileFont(size: 15, weight: .semibold)
                        }
                        .foregroundStyle(MobileTheme.accent)
                    } else {
                        HStack {
                            Text(L(request.guidance)).mobileFont(size: 14).foregroundStyle(MobileTheme.muted).lineSpacing(3)
                            Spacer()
                            if !trimmed.isEmpty {
                                Picker("Mode", selection: $preview) {
                                    Text("Write").tag(false)
                                    Text("Preview").tag(true)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                            }
                        }
                        if preview {
                            MarkdownView(markdown: text).pyCard()
                        } else {
                            TemplatesBar { template in insert((text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " ") + template.body) }
                            mentionSuggestions
                            editor
                        }
                    }
                    if request.requiresText && trimmed.isEmpty {
                        Label(request.event == .requestChanges ? "Add an explanation to request changes." : "Write something before sending.", systemImage: "info.circle").mobileFont(size: 13).foregroundStyle(MobileTheme.amberInk)
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackdrop())
            .safeAreaInset(edge: .bottom) {
                if let alternate, let alternateTitle = request.alternateTitle {
                    PYGlassGroup(spacing: 10) {
                        HStack(spacing: 10) {
                            Button { Task { await perform(using: alternate) } } label: {
                                Text(alternateTitle).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .contentShape(Capsule())
                                    .pyGlass(in: Capsule(), interactive: true, fallback: MobileTheme.card)
                            }
                            .buttonStyle(.pyPlain)
                            Button { Task { await perform() } } label: {
                                HStack(spacing: 6) {
                                    if isSending { PullYardLoader(size: 28, style: .monochrome(.white)) }
                                    Text(request.sendTitle)
                                }
                                .mobileFont(size: 15, weight: .semibold).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .contentShape(Capsule())
                                .pyGlass(in: Capsule(), tint: MobileTheme.greenFill, interactive: true, fallback: MobileTheme.greenFill)
                            }
                            .buttonStyle(.pyPlain)
                        }
                    }
                    .disabled(!canSend)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                } else if request.isApprove {
                    Button { Task { await perform() } } label: {
                        HStack(spacing: 8) {
                            if isSending { PullYardLoader(size: 30, style: .monochrome(.white)) } else { Image(systemName: "checkmark.seal.fill") }
                            Text(isSending ? "Approving…" : "Approve pull request")
                        }
                        .mobileFont(size: 17, weight: .semibold)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .foregroundStyle(.white)
                        .contentShape(Capsule())
                        .pyGlass(in: Capsule(), tint: MobileTheme.greenFill, interactive: true, fallback: MobileTheme.greenFill)
                    }
                    .buttonStyle(.pyPlain)
                    .disabled(!canSend)
                    .padding(.horizontal, 18).padding(.bottom, 10)
                }
            }
            .navigationTitle(L(request.title)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if trimmed.isEmpty { dismiss() } else { confirmClose = true } }.disabled(isSending)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            formatButton("bold") { wrapSelection("**", "**") }
                            formatButton("italic") { wrapSelection("_", "_") }
                            formatButton("chevron.left.forwardslash.chevron.right") { wrapSelection("`", "`") }
                            formatButton("text.quote") { prefixLine("> ") }
                            formatButton("list.bullet") { prefixLine("- ") }
                            formatButton("checklist") { prefixLine("- [ ] ") }
                            formatButton("link") { wrapSelection("[", "](https://)") }
                            formatButton("at") { insert("@") }
                        }
                    }
                    Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                }
                if !request.isApprove && request.alternateTitle == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await perform() } } label: {
                            if isSending { PullYardLoader(size: 30) } else { Text(request.sendTitle).fontWeight(.semibold) }
                        }
                        .disabled(!canSend)
                    }
                }
            }
            .confirmationDialog("Close this draft?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Save draft") { DraftStore.shared.save(text, for: request.draft); dismiss() }
                Button("Discard draft", role: .destructive) { DraftStore.shared.clear(request.draft); dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .pySheetStyle()
        .presentationDetents(request.isApprove ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(!trimmed.isEmpty || isSending)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let saved = DraftStore.shared.text(for: request.draft)
            text = saved.isEmpty ? (request.initialText ?? "") : saved
            showNote = !text.isEmpty
            if !request.isApprove { focused = true }
        }
        .onChange(of: text) { _, value in DraftStore.shared.save(value, for: request.draft) }
    }

    private func formatButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 28, minHeight: 32).contentShape(Rectangle()) }
            .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
    }

    private var mentionToken: String? {
        let prefix = selectionOffset.map { String(text.prefix($0)) } ?? text
        guard let last = prefix.split(whereSeparator: { $0 == " " || $0 == "\n" }).last, last.hasPrefix("@"), !prefix.hasSuffix(" "), !prefix.hasSuffix("\n") else { return nil }
        return String(last.dropFirst())
    }

    @ViewBuilder private var mentionSuggestions: some View {
        if let token = mentionToken {
            let matches = request.participants.filter { token.isEmpty || $0.localizedCaseInsensitiveContains(token) }.prefix(6)
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(matches), id: \.self) { login in
                            Button { completeMention(login, token: token) } label: {
                                HStack(spacing: 6) {
                                    AvatarView(url: URL(string: "https://github.com/\(login).png"), size: 20, fallback: login)
                                    Text("@\(login)").mobileFont(size: 14, weight: .semibold)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .pyGlassCapsule(interactive: true, fallback: MobileTheme.card)
                            }
                            .buttonStyle(.pyPlain)
                        }
                    }
                }
            }
        }
    }

    private func completeMention(_ login: String, token: String) {
        let end = selectionOffset ?? text.count
        let start = max(0, end - token.count - 1)
        let startIndex = text.index(text.startIndex, offsetBy: start)
        let endIndex = text.index(text.startIndex, offsetBy: min(end, text.count))
        text.replaceSubrange(startIndex..<endIndex, with: "@\(login) ")
        selectionOffset = start + login.count + 2
    }

    private func insert(_ value: String) {
        let offset = min(selectionOffset ?? text.count, text.count)
        let index = text.index(text.startIndex, offsetBy: offset)
        text.insert(contentsOf: value, at: index)
        selectionOffset = offset + value.count
    }

    private func wrapSelection(_ prefix: String, _ suffix: String) {
        insert(prefix + suffix)
        if let offset = selectionOffset { selectionOffset = offset - suffix.count }
    }

    private func prefixLine(_ prefix: String) {
        let offset = min(selectionOffset ?? text.count, text.count)
        let head = text.prefix(offset)
        let lineStart = head.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        text.insert(contentsOf: prefix, at: lineStart)
        selectionOffset = offset + prefix.count
    }

    @ViewBuilder private var editor: some View {
        if #available(iOS 18.0, *) {
            SelectionEditor(text: $text, offset: $selectionOffset, focused: $focused)
                .modifier(EditorChrome(focused: focused, isApprove: request.isApprove, isEmpty: text.isEmpty, requiresText: request.requiresText, disabled: isSending))
        } else {
            TextEditor(text: $text)
                .focused($focused)
                .modifier(EditorChrome(focused: focused, isApprove: request.isApprove, isEmpty: text.isEmpty, requiresText: request.requiresText, disabled: isSending))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(MobileTheme.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).mobileFont(size: 14).foregroundStyle(MobileTheme.ink)
                Button("Retry") { Task { await perform() } }.mobileFont(size: 14, weight: .bold)
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(MobileTheme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func summaryStrip(_ summary: ComposerRequest.Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.subtitle).mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted)
            Text(summary.title).mobileFont(size: 16, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(2)
            HStack(spacing: 12) {
                Label(summary.checks.title, systemImage: summary.checks.symbol)
                if let files = summary.files { Label("\(files) files", systemImage: "doc.on.doc") }
            }
            .mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
        }
        .pyCard(padding: 14)
    }

    private func contextQuote(_ comment: PRComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AvatarView(url: comment.user?.avatarUrl, size: 20, fallback: comment.user?.login)
                Text(comment.user?.login ?? "Contributor").mobileFont(size: 13, weight: .semibold)
                if let path = comment.path { Text(path).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.head) }
            }
            Text(comment.body).mobileFont(size: 14).foregroundStyle(MobileTheme.muted).lineLimit(4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(MobileTheme.accent).frame(width: 3) }
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 10))
    }

    private func perform(using action: ((String) async throws -> Void)? = nil) async {
        guard canSend else { return }
        isSending = true; errorMessage = nil
        do {
            try await (action ?? send)(trimmed)
            DraftStore.shared.clear(request.draft)
            isSending = false
            dismiss()
        } catch is OutboxQueued {
            DraftStore.shared.clear(request.draft)
            isSending = false
            dismiss()
        } catch {
            isSending = false
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

private struct ThreadCard: View {
    let thread: ReviewThread
    let me: GitHubUser?
    let expanded: Bool
    var state: ThreadState? = nil
    var showResolved = false
    var canResolve = false
    var reveal: () -> Void = {}
    var toggleResolved: (ThreadState) -> Void = { _ in }
    let expand: () -> Void
    let reply: () -> Void

    var body: some View {
        if let state, state.isResolved, !showResolved {
            Button(action: reveal) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(MobileTheme.green)
                    Text(thread.root.path ?? "Resolved conversation").mobileFont(size: 13, weight: .medium, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Text("Resolved · \(thread.replies.count + 1)").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .background(MobileTheme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous))
            }
            .buttonStyle(.pyPlain)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let state {
                HStack(spacing: 6) {
                    if state.isOutdated { Text("Outdated").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.amberInk).padding(.horizontal, 6).padding(.vertical, 2).background(MobileTheme.amber.opacity(0.15), in: Capsule()) }
                    if state.isResolved { Text("Resolved").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.green).padding(.horizontal, 6).padding(.vertical, 2).background(MobileTheme.green.opacity(0.13), in: Capsule()) }
                }
            }
            if let path = thread.root.path {
                Label(path + ((thread.root.line ?? thread.root.originalLine).map { ":\($0)" } ?? ""), systemImage: "chevron.left.forwardslash.chevron.right")
                    .mobileFont(size: 12, weight: .medium, design: .monospaced).foregroundStyle(MobileTheme.accent).lineLimit(1).truncationMode(.head)
            }
            if let hunk = thread.root.diffHunk, !hunk.isEmpty { DiffHunkView(hunk: hunk) }
            CommentBody(comment: thread.root, isMine: thread.root.user?.isSameAccount(as: me) == true)
            let hidden = expanded ? 0 : max(0, thread.replies.count - 2)
            if hidden > 0 {
                Button(action: expand) {
                    Label("Show \(hidden) more repl\(hidden == 1 ? "y" : "ies")", systemImage: "ellipsis.bubble").mobileFont(size: 13, weight: .semibold)
                }
                .foregroundStyle(MobileTheme.accent)
            }
            ForEach(thread.replies.suffix(expanded ? thread.replies.count : 2)) { item in
                Divider().overlay(MobileTheme.line)
                CommentBody(comment: item, isMine: item.user?.isSameAccount(as: me) == true)
            }
            HStack(spacing: 18) {
                Button(action: reply) { Label("Reply", systemImage: "arrowshape.turn.up.left").mobileFont(size: 14, weight: .semibold) }
                    .foregroundStyle(MobileTheme.accent)
                if let state, canResolve {
                    Button { toggleResolved(state) } label: {
                        Label(state.isResolved ? "Unresolve" : "Resolve", systemImage: state.isResolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
                            .mobileFont(size: 14, weight: .semibold)
                    }
                    .foregroundStyle(state.isResolved ? MobileTheme.muted : MobileTheme.green)
                }
            }
        }
        .pyCard(padding: 14)
    }
}

private struct CommentBody: View {
    let comment: PRComment
    let isMine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(url: comment.user?.avatarUrl, size: 24, fallback: comment.user?.login)
                Text(comment.user?.login ?? "Contributor").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink)
                if isMine { Text("you").mobileFont(size: 11, weight: .bold).foregroundStyle(MobileTheme.accent) }
                Spacer()
                RelativeTime(date: comment.createdAt).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            MarkdownView(markdown: comment.body, collapsible: true)
            ReactionStrip(comment: comment)
        }
        .contextMenu { CommentMenu(comment: comment) }
    }
}

private struct ReactionStrip: View {
    let comment: PRComment
    @Environment(\.pyReact) private var react

    var body: some View {
        let present = comment.reactions?.nonEmpty ?? []
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(present.map(\.0), id: \.self) { kind in
                    let count = comment.reactions?.count(kind) ?? 0
                    Button { react?.handler(comment, kind) } label: {
                        HStack(spacing: 4) {
                            Text(kind.emoji)
                            Text("\(count)").mobileFont(size: 12, weight: .semibold).monospacedDigit().contentTransition(.numericText())
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .pyGlassCapsule(interactive: true, fallback: MobileTheme.sunken)
                    }
                    .buttonStyle(.pyPlain)
                    .accessibilityLabel("\(kind.rawValue) reaction, \(count)")
                }
                if react != nil {
                    Menu {
                        ForEach(ReactionKind.allCases) { kind in
                            Button("\(kind.emoji)  \(kind.rawValue)") { react?.handler(comment, kind) }
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .mobileFont(size: 14)
                            .foregroundStyle(MobileTheme.muted)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .contentShape(Capsule())
                            .pyGlassCapsule(interactive: true, fallback: MobileTheme.sunken)
                    }
                    .accessibilityLabel("Add reaction")
                }
            }
        }
    }
}

private struct EventRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.symbol)
                .mobileFont(size: 12, weight: .semibold)
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(color.opacity(0.12), in: Circle())
            (Text(event.actor.map { "\($0) " } ?? "").fontWeight(.semibold).foregroundStyle(MobileTheme.ink) + Text(event.kind == .commit ? (event.detail.map { "\($0) " } ?? "") : "").font(.system(.caption, design: .monospaced)).foregroundStyle(MobileTheme.muted) + Text(event.text).foregroundStyle(MobileTheme.muted))
                .mobileFont(size: 13)
                .lineLimit(2)
            Spacer(minLength: 4)
            RelativeTime(date: event.date).mobileFont(size: 11).foregroundStyle(MobileTheme.dim)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch event.kind {
        case .merged: MobileTheme.violet
        case .closed: MobileTheme.red
        case .reopened, .ready: MobileTheme.green
        case .forcePush: MobileTheme.amber
        case .reviewRequested: MobileTheme.coral
        default: MobileTheme.slate
        }
    }
}

private struct CommitsRow: View {
    let commits: [TimelineEvent]
    let expanded: Bool
    let expand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: expand) {
                HStack(spacing: 8) {
                    Image(systemName: "smallcircle.filled.circle")
                        .mobileFont(size: 12, weight: .semibold)
                        .foregroundStyle(MobileTheme.slate)
                        .frame(width: 22, height: 22)
                        .background(MobileTheme.slate.opacity(0.12), in: Circle())
                    Text("\(commits.first?.actor ?? "Someone") pushed \(commits.count) commits").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.ink)
                    Spacer()
                    if !expanded { Image(systemName: "chevron.down").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.muted) }
                    RelativeTime(date: commits.last?.date ?? .now).mobileFont(size: 11).foregroundStyle(MobileTheme.dim)
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.pyPlain)
            .disabled(expanded)
            if expanded {
                ForEach(commits) { commit in
                    HStack(spacing: 8) {
                        Text(commit.detail ?? "").mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.accent)
                        Text(commit.text).mobileFont(size: 13).foregroundStyle(MobileTheme.ink).lineLimit(1)
                    }
                    .padding(.leading, 36)
                }
            }
        }
    }
}

private struct CommentMenu: View {
    let comment: PRComment

    var body: some View {
        Button { UIPasteboard.general.string = comment.body } label: { Label("Copy text", systemImage: "doc.on.doc") }
        if let url = comment.htmlUrl {
            Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "link") }
            Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
        }
    }
}

struct CommentCard: View {
    let comment: PRComment
    var isMine = false
    let actionTitle: String
    let action: () -> Void
    var quote: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentBody(comment: comment, isMine: isMine)
            Button(action: action) { Label(actionTitle, systemImage: "quote.bubble").mobileFont(size: 14, weight: .semibold) }
                .foregroundStyle(MobileTheme.accent)
        }
        .pyCard(padding: 14)
        .overlay(alignment: .leading) {
            if isMine { RoundedRectangle(cornerRadius: 2).fill(MobileTheme.accent).frame(width: 3).padding(.vertical, 12) }
        }
    }
}

struct ReviewCard: View {
    let review: PRReview

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).mobileFont(size: 18, weight: .semibold).foregroundStyle(color).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(review.user?.login ?? "Contributor").mobileFont(size: 14, weight: .semibold)
                    Text(title.lowercased()).mobileFont(size: 14).foregroundStyle(color)
                    Spacer()
                    if let date = review.submittedAt { RelativeTime(date: date).mobileFont(size: 12).foregroundStyle(MobileTheme.muted) }
                }
                if let body = review.body, !body.isEmpty { MarkdownView(markdown: body, collapsible: true) }
            }
            .foregroundStyle(MobileTheme.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous).stroke(color.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch review.state { case "APPROVED": "Approved"; case "CHANGES_REQUESTED": "Requested changes"; case "DISMISSED": "Dismissed review"; default: "Reviewed" }
    }
    private var symbol: String { switch review.state { case "APPROVED": "checkmark.seal.fill"; case "CHANGES_REQUESTED": "arrow.uturn.backward.circle.fill"; default: "text.bubble.fill" } }
    private var color: Color { switch review.state { case "APPROVED": MobileTheme.green; case "CHANGES_REQUESTED": MobileTheme.red; default: MobileTheme.accent } }
}

struct CheckRow: View {
    let check: CheckRun

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).mobileFont(size: 17, weight: .semibold).foregroundStyle(color).frame(width: 24)
                .symbolEffect(.pulse, isActive: check.isPending)
            VStack(alignment: .leading, spacing: 4) {
                Text(check.name).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                Text(statusLine).mobileFont(size: 12, weight: .medium).foregroundStyle(color)
                if let summary = check.output?.summary ?? check.output?.title, !summary.isEmpty {
                    Text(MarkdownParser.inline(summary)).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            if let url = check.htmlUrl {
                Link(destination: url) { Image(systemName: "arrow.up.right").mobileFont(size: 13, weight: .semibold) }
                    .accessibilityLabel("Open \(check.name) on GitHub")
            }
        }
        .pyCard(padding: 14)
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        guard let started = check.startedAt else { return check.statusTitle }
        let end = check.completedAt ?? .now
        let seconds = Int(max(0, end.timeIntervalSince(started)))
        let duration = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        if check.isPending { return "Running for \(duration)" }
        if check.isFailure { return "\(check.statusTitle) after \(duration)" }
        if check.isSuccess { return "Passed in \(duration)" }
        return check.statusTitle
    }
    private var icon: String { check.isPending ? "clock.fill" : check.isSuccess ? "checkmark.circle.fill" : check.isSkipped ? "minus.circle.fill" : "xmark.circle.fill" }
    private var color: Color { check.isPending ? MobileTheme.amber : check.isSuccess ? MobileTheme.green : check.isSkipped ? MobileTheme.slate : MobileTheme.red }
}

private struct ConflictPill: View {
    var body: some View {
        Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
            .mobileFont(size: 11, weight: .semibold, design: .rounded)
            .foregroundStyle(MobileTheme.amberInk)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(MobileTheme.amber.opacity(0.15), in: Capsule())
    }
}

struct BranchCard: View {
    let head: String
    let base: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(MobileTheme.accent)
            Text(head.isEmpty ? "head" : head).lineLimit(1).truncationMode(.middle).foregroundStyle(MobileTheme.ink)
            Image(systemName: "arrow.right").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.muted).accessibilityLabel("into")
            Text(base.isEmpty ? "base" : base).lineLimit(1).foregroundStyle(MobileTheme.muted)
            Spacer(minLength: 0)
        }
        .mobileFont(size: 13, weight: .medium, design: .monospaced)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: PYRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct MetricCard: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).mobileFont(size: 19, weight: .semibold, design: .rounded).foregroundStyle(color).monospacedDigit()
            Text(label).mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted)
        }
        .pyCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

struct SectionEyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View { Text(L(title)).mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted).accessibilityAddTraits(.isHeader) }
}

struct AvatarView: View {
    let url: URL?
    let size: CGFloat
    var fallback: String? = nil
    @Environment(\.displayScale) private var scale

    var body: some View {
        AsyncImage(url: sizedURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(MobileTheme.line, lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let initials = (fallback ?? "").split(whereSeparator: { "/-_ ".contains($0) }).prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        let palette = [MobileTheme.accent, MobileTheme.violet, MobileTheme.coral, MobileTheme.green, MobileTheme.amber, MobileTheme.sky]
        let tint = palette[(fallback ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count]
        return Circle().fill(tint.opacity(0.18)).overlay {
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(tint)
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded)).foregroundStyle(tint)
            }
        }
    }

    private var sizedURL: URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "s" || $0.name == "size" }
        items.append(URLQueryItem(name: "s", value: String(Int(size * scale))))
        components.queryItems = items
        return components.url ?? url
    }
}

private struct DetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShimmerBar(width: 120, height: 12)
            ShimmerBar(height: 26)
            ShimmerBar(width: 220, height: 26)
            HStack(spacing: 8) { Circle().fill(MobileTheme.line).frame(width: 24, height: 24); ShimmerBar(width: 140, height: 14) }
            ShimmerBar(height: 40, radius: PYRadius.small)
            ShimmerBar(height: 120, radius: PYRadius.card)
            HStack(spacing: 10) { ShimmerBar(height: 64, radius: PYRadius.card); ShimmerBar(height: 64, radius: PYRadius.card); ShimmerBar(height: 64, radius: PYRadius.card) }
            Spacer()
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading pull request")
    }
}

struct ShimmerBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(MobileTheme.line)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, MobileTheme.lineStrong, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
            .accessibilityHidden(true)
    }
}

private struct EditorChrome: ViewModifier {
    let focused: Bool
    let isApprove: Bool
    let isEmpty: Bool
    let requiresText: Bool
    let disabled: Bool

    func body(content: Content) -> some View {
        content
            .mobileFont(size: 16).scrollContentBackground(.hidden).padding(10)
            .frame(minHeight: isApprove ? 110 : 220)
            .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(focused ? MobileTheme.accent.opacity(0.5) : MobileTheme.line, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(requiresText ? "Write your message…" : "Write an optional note…").mobileFont(size: 16).foregroundStyle(MobileTheme.dim).padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false)
                }
            }
            .disabled(disabled)
    }
}

@available(iOS 18.0, *)
private struct SelectionEditor: View {
    @Binding var text: String
    @Binding var offset: Int?
    var focused: FocusState<Bool>.Binding
    @State private var selection: TextSelection?

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .focused(focused)
            .onChange(of: selection) { _, value in
                guard let value, case let .selection(range) = value.indices else { return }
                offset = text.distance(from: text.startIndex, to: range.upperBound)
            }
            .onChange(of: offset) { _, value in
                guard let value, value <= text.count else { return }
                let index = text.index(text.startIndex, offsetBy: value)
                if case let .selection(range) = selection?.indices, range.upperBound == index { return }
                selection = TextSelection(insertionPoint: index)
            }
    }
}

private struct SectionSwitcher: View {
    @Binding var selection: PRSection
    let title: (PRSection) -> String
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PRSection.allCases) { item in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { selection = item }
                } label: {
                    Text(title(item))
                        .mobileFont(size: 14, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selection == item ? Color.white : MobileTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if selection == item {
                                Capsule()
                                    .fill(MobileTheme.accentFill)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.pyPlain)
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(4)
        .pyGlassCapsule(fallback: MobileTheme.card)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
