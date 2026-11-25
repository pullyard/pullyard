import SwiftUI

struct IssueDetailView: View {
    let key: PRKey
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var issue: GHIssue?
    @State private var comments: [PRComment] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var composer: ComposerRequest?
    @State private var confirmClose = false

    var body: some View {
        Group {
            if let issue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        hero(issue)
                        if let body = issue.body, !MarkdownParser.blocks(body).isEmpty {
                            MarkdownView(markdown: body, collapsible: true).pyCard()
                        }
                        if !comments.isEmpty {
                            SectionEyebrow("Comments · \(comments.count)").padding(.top, 4)
                            ForEach(comments) { comment in
                                CommentCard(comment: comment, isMine: comment.user?.isSameAccount(as: model.user) == true, actionTitle: "Quote reply") {
                                    openComment(quoting: comment)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
                .pullToRefreshLogo(isRefreshing: isLoading)
            } else if let loadError {
                ScrollView {
                    ErrorStateView(title: "Couldn't load \(key.repo) #\(key.number)", message: loadError) { Task { await load() } }.padding(.top, 80)
                }
                .refreshable { await load() }
            } else {
                PullYardLoader(title: "Loading issue…", size: 72).frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    if let url = issue?.htmlUrl {
                        Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
                        ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                } label: { RefreshGlyph(isRefreshing: isLoading && issue != nil, symbol: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let issue {
                PYGlassGroup(spacing: 10) {
                    HStack(spacing: 10) {
                        Button { openComment() } label: {
                            Label("Comment", systemImage: "text.bubble")
                                .mobileFont(size: 15, weight: .semibold).foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .contentShape(Capsule())
                                .pyGlass(in: Capsule(), tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
                        }
                        .buttonStyle(.pyPlain)
                        Button { if issue.isOpen { confirmClose = true } else { Task { await setOpen(true) } } } label: {
                            Label(issue.isOpen ? "Close" : "Reopen", systemImage: issue.isOpen ? "checkmark.circle" : "arrow.uturn.left.circle")
                                .mobileFont(size: 15, weight: .semibold).foregroundStyle(issue.isOpen ? MobileTheme.violet : MobileTheme.green)
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .contentShape(Capsule())
                                .pyGlass(in: Capsule(), tint: (issue.isOpen ? MobileTheme.violet : MobileTheme.green).opacity(0.14), interactive: true, fallback: MobileTheme.card)
                        }
                        .buttonStyle(.pyPlain)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            }
        }
        .environment(\.pyReact, ReactAction { comment, kind in react(comment, kind) })
        .sheet(item: $composer) { request in
            ComposerSheet(request: { var copy = request; copy.participants = Array(Set(([issue?.user?.login] + comments.map(\.user?.login)).compactMap { $0 })).sorted(); return copy }()) { body in
                try await model.addComment(key, body: body)
                feedback.success("Comment posted")
                Task { await load() }
            }
        }
        .confirmationDialog("Close this issue?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close issue") { Task { await setOpen(false) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
        .feedbackChrome { Task { await load() } }
    }

    private func hero(_ issue: GHIssue) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                let color = issue.isOpen ? MobileTheme.green : (issue.stateReason == "not_planned" ? MobileTheme.slate : MobileTheme.violet)
                Label(issue.isOpen ? "Open" : (issue.stateReason == "not_planned" ? "Not planned" : "Closed"), systemImage: issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle.fill")
                    .mobileFont(size: 11, weight: .semibold, design: .rounded)
                    .foregroundStyle(color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color.opacity(0.13), in: Capsule())
                Text("Issue").mobileFont(size: 12, weight: .medium).foregroundStyle(MobileTheme.muted)
                Spacer()
                RelativeTime(date: issue.updatedAt, prefix: "Updated").mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            Text(issue.title).mobileFont(size: 24, design: .serif).foregroundStyle(MobileTheme.ink).textSelection(.enabled)
            HStack(spacing: 8) {
                AvatarView(url: issue.user?.avatarUrl, size: 24, fallback: issue.user?.login)
                Text(issue.user?.login ?? "Contributor").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink)
                Text("opened this").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
                RelativeTime(date: issue.createdAt).mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
            }
            if let labels = issue.labels, !labels.isEmpty {
                FlowRow(spacing: 6) { ForEach(labels, id: \.name) { LabelChip(label: $0) } }
            }
            if let assignees = issue.assignees, !assignees.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(MobileTheme.muted)
                    ForEach(assignees, id: \.login) { user in
                        AvatarView(url: user.avatarUrl, size: 22, fallback: user.login)
                    }
                    Text(assignees.map(\.login).joined(separator: ", ")).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(1)
                }
            }
        }
    }

    private func openComment(quoting comment: PRComment? = nil) {
        let quote = comment.map { item in item.body.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).map { "> \($0)" }.joined(separator: "\n") + "\n\n@\(item.user?.login ?? "") " }
        composer = ComposerRequest(title: "Add a comment", mode: .comment, draft: DraftKey(pull: key, kind: .comment), initialText: quote)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let key = key
        let model = model
        let issueTask = Task { () -> Result<GHIssue, Error> in
            do { return .success(try await model.issue(key)) } catch { return .failure(error) }
        }
        let commentsTask = Task { () -> Result<[PRComment], Error> in
            do { return .success(try await model.comments(key)) } catch { return .failure(error) }
        }
        switch await issueTask.value {
        case let .success(value): withAnimation(.snappy) { issue = value }; loadError = nil
        case let .failure(error):
            if error.isCancellation { return }
            if issue == nil { loadError = error.localizedDescription } else { feedback.error(error, key: "issue") }
        }
        if case let .success(value) = await commentsTask.value { comments = value }
        if issue != nil { await model.markNotificationsRead(forIssue: key) }
    }

    private func setOpen(_ open: Bool) async {
        do {
            try await model.setIssueState(key, open: open)
            feedback.success(open ? "Issue reopened" : "Issue closed")
            await load()
        } catch {
            feedback.error(error, key: "issue-state")
        }
    }

    private func react(_ comment: PRComment, _ kind: ReactionKind) {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        let previous = comments
        var rollup = comments[index].reactions ?? ReactionRollup()
        rollup.increment(kind)
        withAnimation(.snappy) { comments[index].reactions = rollup }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do { try await model.addReaction(key, commentID: comment.id, reviewComment: false, content: kind) }
            catch { comments = previous; feedback.error(error, key: "reaction") }
        }
    }
}
