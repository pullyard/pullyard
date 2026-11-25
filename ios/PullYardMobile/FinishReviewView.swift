import SwiftUI

struct FinishReviewView: View {
    let key: PRKey
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var review: PRReview?
    @State private var comments: [PRComment] = []
    @State private var summary = ""
    @State private var loading = true
    @State private var submitting: ReviewEvent?
    @State private var editing: PRComment?
    @State private var deleting: PRComment?
    @State private var confirmDiscard = false
    @State private var errorMessage: String?

    private var isAuthor: Bool { model.cachedDetail(key).map { model.isAuthor(of: $0.pull) } ?? false }
    private var summaryDraft: DraftKey { DraftKey(pull: key, kind: .pendingReview(review?.id ?? 0)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if loading {
                    PullYardLoader(title: "Loading your review…", size: 64).frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if review == nil {
                    PYEmptyState(title: "No pending review", message: "Long-press a line in Files changed and choose Add to review to start one.") {
                        NavigationLink(value: Route.files(key)) { Text("Open changed files") }.pyGlassButton(prominent: true)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill").mobileFont(size: 14).foregroundStyle(MobileTheme.red)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MobileTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    SectionEyebrow("Summary")
                    TemplatesBar { template in summary += (summary.isEmpty || summary.hasSuffix("\n") ? "" : "\n") + template.body }
                    TextEditor(text: $summary)
                        .mobileFont(size: 15)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 110)
                        .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MobileTheme.line))
                        .overlay(alignment: .topLeading) {
                            if summary.isEmpty { Text("Overall feedback (optional for Comment and Approve)").mobileFont(size: 15).foregroundStyle(MobileTheme.dim).padding(14).allowsHitTesting(false) }
                        }
                        .onChange(of: summary) { _, value in DraftStore.shared.save(value, for: summaryDraft) }
                    SectionEyebrow(comments.isEmpty ? "No comments yet" : "\(comments.count) pending comment\(comments.count == 1 ? "" : "s")")
                    ForEach(comments) { comment in
                        VStack(alignment: .leading, spacing: 8) {
                            if let path = comment.path {
                                Label(path + ((comment.line ?? comment.originalLine).map { ":\($0)" } ?? ""), systemImage: "chevron.left.forwardslash.chevron.right")
                                    .mobileFont(size: 12, weight: .medium, design: .monospaced).foregroundStyle(MobileTheme.accent).lineLimit(1).truncationMode(.head)
                            }
                            if let hunk = comment.diffHunk { DiffHunkView(hunk: hunk, maxLines: 4) }
                            MarkdownView(markdown: comment.body)
                            HStack(spacing: 18) {
                                Button { editing = comment } label: { Label("Edit", systemImage: "pencil").mobileFont(size: 14, weight: .semibold) }
                                Button(role: .destructive) { deleting = comment } label: { Label("Delete", systemImage: "trash").mobileFont(size: 14, weight: .semibold) }
                                    .foregroundStyle(MobileTheme.red)
                            }
                        }
                        .pyCard(padding: 14)
                    }
                }
            }
            .padding(16)
        }
        .background(BrandBackdrop())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if review != nil {
                PYGlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        submitButton(.comment, title: "Comment", tint: MobileTheme.accentFill)
                        if !isAuthor {
                            submitButton(.requestChanges, title: "Changes", tint: MobileTheme.redFill)
                            submitButton(.approve, title: "Approve", tint: MobileTheme.greenFill)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
            }
        }
        .navigationTitle("Finish review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if review != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDiscard = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Discard review")
                }
            }
        }
        .sheet(item: $editing) { comment in
            ComposerSheet(request: ComposerRequest(title: "Edit comment", mode: .comment, draft: DraftKey(pull: key, kind: .reply(-comment.id)), initialText: comment.body)) { body in
                try await model.editReviewComment(repo: key.repo, commentID: comment.id, body: body)
                if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                    let old = comments[index]
                    comments[index] = PRComment(id: old.id, user: old.user, body: body, createdAt: old.createdAt, htmlUrl: old.htmlUrl, path: old.path, line: old.line, inReplyToId: old.inReplyToId, diffHunk: old.diffHunk, originalLine: old.originalLine)
                }
            }
        }
        .confirmationDialog("Delete this comment?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete comment", role: .destructive) { if let deleting { Task { await delete(deleting) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Discard your pending review?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard review", role: .destructive) { Task { await discard() } }
            Button("Keep it", role: .cancel) {}
        } message: { Text("Comments you added to this pending review will be deleted.") }
        .task { await load() }
        .feedbackChrome { Task { await load() } }
    }

    private func submitButton(_ event: ReviewEvent, title: String, tint: Color) -> some View {
        Button { Task { await submit(event) } } label: {
            HStack(spacing: 6) {
                if submitting == event { PullYardLoader(size: 26, style: .monochrome(.white)) }
                Text(L(title))
            }
            .mobileFont(size: 15, weight: .semibold).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Capsule())
            .pyGlass(in: Capsule(), tint: tint, interactive: true, fallback: tint)
        }
        .buttonStyle(.pyPlain)
        .disabled(submitting != nil || (event == .requestChanges && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    private func load() async {
        loading = review == nil
        defer { loading = false }
        do {
            let reviews = try await model.reviews(key)
            review = reviews.first(where: \.isPending)
            if let review {
                comments = try await model.pendingComments(key, reviewID: review.id)
                if summary.isEmpty { summary = DraftStore.shared.text(for: summaryDraft) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit(_ event: ReviewEvent) async {
        guard let review else { return }
        submitting = event
        defer { submitting = nil }
        do {
            try await model.submitPendingReview(key, reviewID: review.id, event: event, body: summary.trimmingCharacters(in: .whitespacesAndNewlines))
            DraftStore.shared.clear(summaryDraft)
            if event != .comment { model.noteReviewed(key) }
            feedback.success(event == .approve ? "Approved" : event == .requestChanges ? "Changes requested" : "Review submitted")
            model.refreshAll()
            router.popTo(.pull(key), in: model.selectedTab)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ comment: PRComment) async {
        do {
            try await model.deleteReviewComment(repo: key.repo, commentID: comment.id)
            withAnimation(.snappy) { comments.removeAll { $0.id == comment.id } }
        } catch {
            feedback.error(error, key: "delete-pending")
        }
    }

    private func discard() async {
        guard let review else { return }
        do {
            try await model.deletePendingReview(key, reviewID: review.id)
            DraftStore.shared.clear(summaryDraft)
            feedback.success("Pending review discarded")
            router.popTo(.pull(key), in: model.selectedTab)
        } catch {
            feedback.error(error, key: "discard")
        }
    }
}
