import SwiftUI

struct MergeReadinessCard: View {
    let insight: PRInsight
    let checks: ChecksSummary
    let openChecks: () -> Void
    let openConversation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: headline.symbol)
                    .mobileFont(size: 20, weight: .semibold)
                    .foregroundStyle(headline.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline.title).mobileFont(size: 16, weight: .semibold).foregroundStyle(MobileTheme.ink)
                    Text(headline.subtitle).mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                }
                Spacer()
                if insight.autoMergeEnabled {
                    Label("Auto-merge", systemImage: "bolt.fill").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.violet)
                        .padding(.horizontal, 8).padding(.vertical, 4).pyGlassCapsule(tint: MobileTheme.violet.opacity(0.2), fallback: MobileTheme.violet.opacity(0.12))
                }
            }
            Divider().overlay(MobileTheme.line)
            row(reviewTitle, symbol: reviewSymbol, color: reviewColor, action: openConversation)
            row(checks.title, symbol: checks.symbol, color: checksColor, action: openChecks)
            if insight.unresolvedCount > 0 {
                row("\(insight.unresolvedCount) unresolved conversation\(insight.unresolvedCount == 1 ? "" : "s")", symbol: "bubble.left.and.exclamationmark.bubble.right.fill", color: MobileTheme.amber, action: openConversation)
            }
            if insight.hasConflicts {
                row("Conflicts with the base branch", symbol: "exclamationmark.triangle.fill", color: MobileTheme.red, action: nil)
            } else if insight.isBehind {
                row("Branch is behind the base branch", symbol: "arrow.down.circle.fill", color: MobileTheme.amber, action: nil)
            } else {
                row("No conflicts with the base branch", symbol: "checkmark.circle.fill", color: MobileTheme.green, action: nil)
            }
        }
        .pyCard()
    }

    private func row(_ title: String, symbol: String, color: Color, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 22)
                Text(title).mobileFont(size: 14, weight: .medium).foregroundStyle(MobileTheme.ink)
                Spacer()
                if action != nil { Image(systemName: "chevron.right").mobileFont(size: 11, weight: .semibold).foregroundStyle(MobileTheme.muted) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pyPlain)
        .disabled(action == nil)
    }

    private var headline: (title: String, subtitle: String, symbol: String, color: Color) {
        if insight.isDraft { return ("Draft", "Mark it ready for review when it's done.", "circle.dashed", MobileTheme.slate) }
        if insight.hasConflicts { return ("Merge blocked", "Resolve conflicts on desktop or GitHub.", "xmark.octagon.fill", MobileTheme.red) }
        switch insight.mergeStateStatus {
        case "CLEAN", "HAS_HOOKS": return ("Ready to merge", "All requirements are met.", "checkmark.seal.fill", MobileTheme.green)
        case "UNSTABLE": return ("Mergeable with failing checks", "Some non-required checks are failing.", "exclamationmark.circle.fill", MobileTheme.amber)
        case "BEHIND": return ("Update required", "The branch is behind its base.", "arrow.down.circle.fill", MobileTheme.amber)
        case "BLOCKED": return ("Merge blocked", "Required reviews or checks are missing.", "lock.fill", MobileTheme.amber)
        default: return ("Checking merge status", "GitHub is still computing mergeability.", "hourglass", MobileTheme.slate)
        }
    }

    private var reviewTitle: String {
        switch insight.reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: insight.reviewers.contains { $0.state == .approved } ? "Approved" : "No required reviews"
        }
    }
    private var reviewSymbol: String {
        switch insight.reviewDecision { case "APPROVED": "checkmark.seal.fill"; case "CHANGES_REQUESTED": "arrow.uturn.backward.circle.fill"; default: "eye.circle.fill" }
    }
    private var reviewColor: Color {
        switch insight.reviewDecision { case "APPROVED": MobileTheme.green; case "CHANGES_REQUESTED": MobileTheme.red; default: MobileTheme.amber }
    }
    private var checksColor: Color {
        switch checks { case .failing: MobileTheme.red; case .running: MobileTheme.amber; case .passed: MobileTheme.green; default: MobileTheme.muted }
    }
}

struct ReviewersCard: View {
    let insight: PRInsight
    let me: GitHubUser?
    let canRerequest: Bool
    let rerequest: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow("Reviewers")
            if insight.reviewers.isEmpty {
                Text("No reviewers yet.").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
            }
            ForEach(insight.reviewers) { reviewer in
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(url: reviewer.avatarUrl, size: 30, fallback: reviewer.login)
                        Image(systemName: badge(reviewer.state))
                            .mobileFont(size: 10, weight: .bold)
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(color(reviewer.state), in: Circle())
                            .overlay(Circle().stroke(MobileTheme.card, lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(reviewer.login).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.ink)
                            if GitHubUser(login: reviewer.login).isSameAccount(as: me) { Text("you").mobileFont(size: 11, weight: .bold).foregroundStyle(MobileTheme.accent) }
                        }
                        Text(title(reviewer.state)).mobileFont(size: 12).foregroundStyle(color(reviewer.state))
                    }
                    Spacer()
                    if canRerequest && !reviewer.isTeam && reviewer.state != .requested {
                        Button("Re-request") { rerequest(reviewer.login) }
                            .mobileFont(size: 13, weight: .semibold)
                            .pyGlassButton()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .pyCard()
    }

    private func badge(_ state: ReviewerStatus.State) -> String {
        switch state { case .approved: "checkmark"; case .changesRequested: "xmark"; case .commented: "text.bubble.fill"; case .dismissed: "minus"; case .requested: "clock" }
    }
    private func color(_ state: ReviewerStatus.State) -> Color {
        switch state { case .approved: MobileTheme.green; case .changesRequested: MobileTheme.red; case .commented: MobileTheme.accent; case .dismissed: MobileTheme.slate; case .requested: MobileTheme.amber }
    }
    private func title(_ state: ReviewerStatus.State) -> String {
        switch state { case .approved: "Approved"; case .changesRequested: "Requested changes"; case .commented: "Commented"; case .dismissed: "Dismissed"; case .requested: "Awaiting review" }
    }
}

struct MetadataCard: View {
    let insight: PRInsight

    var body: some View {
        if !insight.labels.isEmpty || !insight.assignees.isEmpty || insight.milestone != nil || !insight.closingIssues.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !insight.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionEyebrow("Labels")
                        FlowRow(spacing: 6) { ForEach(insight.labels, id: \.name) { LabelChip(label: $0) } }
                    }
                }
                if !insight.assignees.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionEyebrow("Assignees")
                        HStack(spacing: 8) {
                            ForEach(insight.assignees, id: \.login) { user in
                                HStack(spacing: 5) {
                                    AvatarView(url: user.avatarUrl, size: 22, fallback: user.login)
                                    Text(user.login).mobileFont(size: 13, weight: .medium)
                                }
                            }
                        }
                    }
                }
                if let milestone = insight.milestone {
                    Label(milestone, systemImage: "signpost.right.fill").mobileFont(size: 14).foregroundStyle(MobileTheme.ink)
                }
                ForEach(insight.closingIssues, id: \.number) { issue in
                    Label {
                        Text("Closes #\(issue.number) ").foregroundStyle(MobileTheme.green).fontWeight(.semibold) + Text(issue.title).foregroundStyle(MobileTheme.ink)
                    } icon: {
                        Image(systemName: "checkmark.circle").foregroundStyle(MobileTheme.green)
                    }
                    .mobileFont(size: 14)
                    .lineLimit(2)
                }
            }
            .pyCard()
        }
    }
}

struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct MergeSheet: View {
    let pull: PullRequest
    let insight: PRInsight
    let merge: (MergeMethod, String?, String?, Bool) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mobile.merge.method") private var savedMethod = MergeMethod.squash.rawValue
    @AppStorage("mobile.merge.deleteBranch") private var deleteBranch = true
    @State private var method: MergeMethod = .squash
    @State private var title = ""
    @State private var message = ""
    @State private var isMerging = false
    @State private var errorMessage: String?
    @State private var confirming = false

    private var canDeleteBranch: Bool { !insight.deleteBranchOnMerge && !insight.isCrossRepository }

    private var baseName: String { pull.base.ref.isEmpty ? "base" : pull.base.ref }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pull.title).mobileFont(size: 18, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(3)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                            Text(insight.headRefName).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                            Text(baseName).lineLimit(1)
                        }
                        .mobileFont(size: 13, weight: .medium, design: .monospaced)
                        .foregroundStyle(MobileTheme.muted)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                            .mobileFont(size: 14).foregroundStyle(MobileTheme.red)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(MobileTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    SectionEyebrow("Merge method")
                    VStack(spacing: 8) {
                        ForEach(insight.mergeMethods) { option in
                            Button { withAnimation(.snappy) { method = option } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: option.symbol)
                                        .mobileFont(size: 16, weight: .semibold)
                                        .foregroundStyle(method == option ? Color.white : MobileTheme.violet)
                                        .frame(width: 36, height: 36)
                                        .background(method == option ? MobileTheme.violetFill : MobileTheme.violet.opacity(0.12), in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                                        Text(detail(option)).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                                    }
                                    Spacer()
                                    Image(systemName: method == option ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(method == option ? MobileTheme.violet : MobileTheme.dim)
                                }
                                .padding(12)
                                .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(method == option ? MobileTheme.violet : MobileTheme.line, lineWidth: method == option ? 1.5 : 1))
                            }
                            .buttonStyle(.pyPlain)
                            .accessibilityAddTraits(method == option ? .isSelected : [])
                        }
                    }
                    if method != .rebase {
                        SectionEyebrow("Commit")
                        VStack(alignment: .leading, spacing: 0) {
                            TextField("Commit title", text: $title, axis: .vertical)
                                .mobileFont(size: 15, weight: .medium)
                                .padding(12)
                            Divider().overlay(MobileTheme.line)
                            TextField("Description (optional)", text: $message, axis: .vertical)
                                .lineLimit(3...8)
                                .mobileFont(size: 14)
                                .padding(12)
                        }
                        .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MobileTheme.line))
                    }
                    if canDeleteBranch {
                        Toggle(isOn: $deleteBranch) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Delete branch after merge", systemImage: "trash").mobileFont(size: 15, weight: .medium)
                                Text(insight.headRefName).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .tint(MobileTheme.violetFill)
                        .padding(12)
                        .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MobileTheme.line))
                    } else if insight.deleteBranchOnMerge {
                        Label("GitHub deletes the branch automatically after merge.", systemImage: "info.circle").mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                    }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BrandBackdrop())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button { confirming = true } label: {
                    HStack(spacing: 8) {
                        if isMerging { PullYardLoader(size: 30, style: .monochrome(.white)) } else { Image(systemName: "arrow.triangle.merge") }
                        Text(isMerging ? "Merging…" : "\(method.short) into \(baseName)…")
                    }
                    .mobileFont(size: 17, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .contentShape(Capsule())
                    .pyGlass(in: Capsule(), tint: MobileTheme.violetFill, interactive: true, fallback: MobileTheme.violetFill)
                }
                .buttonStyle(.pyPlain)
                .disabled(isMerging)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
            }
            .confirmationDialog("Merge #\(pull.number) into \(baseName)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("\(method.title)\(canDeleteBranch && deleteBranch ? " and delete branch" : "")") { Task { await perform() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This changes \(baseName) on GitHub and can't be undone from PullYard.")
            }
            .navigationTitle("Merge #\(pull.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isMerging) } }
        }
        .pySheetStyle()
        .presentationDetents([.large])
        .interactiveDismissDisabled(isMerging)
        .onAppear {
            let preferred = MergeMethod(rawValue: savedMethod) ?? .squash
            method = insight.mergeMethods.contains(preferred) ? preferred : (insight.mergeMethods.first ?? .merge)
            title = "\(pull.title) (#\(pull.number))"
        }
    }

    private func detail(_ option: MergeMethod) -> String {
        switch option {
        case .squash: "All commits become one commit on \(baseName)."
        case .merge: "Keeps every commit and adds a merge commit."
        case .rebase: "Replays each commit on top of \(baseName)."
        }
    }

    private func perform() async {
        isMerging = true; errorMessage = nil
        savedMethod = method.rawValue
        do {
            try await merge(method, method == .rebase ? nil : title, method == .rebase ? nil : message, canDeleteBranch && deleteBranch)
            isMerging = false
            dismiss()
        } catch {
            isMerging = false
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}
