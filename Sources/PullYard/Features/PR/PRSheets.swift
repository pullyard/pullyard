import SwiftUI

enum MergeMethod: String, CaseIterable, Identifiable {
    case MERGE, SQUASH, REBASE
    var id: String { rawValue }

    var title: String {
        switch self {
        case .MERGE: return "Merge commit"
        case .SQUASH: return "Squash and merge"
        case .REBASE: return "Rebase and merge"
        }
    }

    var short: String {
        switch self {
        case .MERGE: return "Merge"
        case .SQUASH: return "Squash"
        case .REBASE: return "Rebase"
        }
    }

    var symbol: String {
        switch self {
        case .MERGE: return "arrow.triangle.merge"
        case .SQUASH: return "square.stack.3d.down.right"
        case .REBASE: return "arrow.triangle.branch"
        }
    }
}

struct SheetFrame<Content: View>: View {
    let title: String
    var model: PRDetailModel?
    @ViewBuilder let content: Content

    init(title: String, model: PRDetailModel? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.model = model
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(title).font(.syTitle3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let error = model?.actionError {
                SheetErrorRow(message: error) { model?.actionError = nil }
            }
            content
        }
        .padding(20)
        .frame(width: 560)
        .surface(.panel)
        .animation(Motion.fade, value: model?.actionError)
        .onAppear {
            model?.actionError = nil
            model?.sheetDepth += 1
        }
        .onDisappear {
            if let model {
                model.sheetDepth = max(0, model.sheetDepth - 1)
                if model.sheetDepth == 0, model.busy == false {
                    model.actionError = model.deferredError
                    model.deferredError = nil
                }
            }
        }
    }
}

struct SheetErrorRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syRed).accessibilityHidden(true)
            Text(message).font(.syCallout).foregroundStyle(Color.syText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.syCaption.weight(.semibold)) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
        }
        .padding(Space.m + 2)
        .background(RoundedRectangle(cornerRadius: Radius.m).fill(Color.syRed.opacity(Tint.banner)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m).strokeBorder(Color.syRed.opacity(Tint.strong)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .onAppear { AccessibilityNotification.Announcement("Error: \(message)").post() }
    }
}

struct ReviewSheet: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var event: String
    @State private var confirmDiscard = false

    init(model: PRDetailModel, pr: PullRequestDetail, initialEvent: String = "COMMENT") {
        self.model = model
        self.pr = pr
        let unsupported = initialEvent == "REQUEST_CHANGES" && !model.features.requestChanges
        _event = State(initialValue: pr.viewerDidAuthor || unsupported ? "COMMENT" : initialEvent)
    }

    private var text: String { model.summaryDraft }

    var body: some View {
        @Bindable var model = model
        SheetFrame(title: "Review \(model.provider.numberPrefix)\(pr.number)", model: model) {
            if model.restoredDrafts {
                Label("Restored from your last session", systemImage: "clock.arrow.circlepath")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            if !pr.viewerDidAuthor {
                Picker("Verdict", selection: $event) {
                    Text("Comment").tag("COMMENT")
                    Text("Approve").tag("APPROVE").disabled(!(pr.viewerCanApprove ?? !pr.viewerDidAuthor) || pr.viewerApproved == true)
                    if model.features.requestChanges {
                        Text("Request changes").tag("REQUEST_CHANGES")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(verdictTint)
                .accessibilityLabel("Verdict")
            } else {
                Text("You opened this \(model.provider.requestTitle), so you can only comment.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            ComposerBox(text: $model.summaryDraft, placeholder: event == "APPROVE" ? "Summary (optional)" : "Review summary", minHeight: 120)
                .frame(maxHeight: 240)
            if !model.pending.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plural(model.pending.count, "pending inline comment", "pending inline comments"))
                        .font(.sy(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.syMuted)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(model.pending) { c in
                                HStack(spacing: 6) {
                                    Text("\((c.path as NSString).lastPathComponent):\(c.line)")
                                        .font(.syCaption.monospaced())
                                        .foregroundStyle(Color.syText)
                                        .lineLimit(1)
                                        .help(c.path)
                                    Text(c.body.replacingOccurrences(of: "\n", with: " "))
                                        .font(.syCaption)
                                        .foregroundStyle(Color.syMuted)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
            }
            if let reason = disabledReason {
                Label(reason, systemImage: "info.circle")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            HStack {
                if !model.pending.isEmpty {
                    Button("Discard pending comments", role: .destructive) { confirmDiscard = true }
                        .confirmationDialog("Discard \(plural(model.pending.count, "pending comment", "pending comments"))?", isPresented: $confirmDiscard) {
                            Button("Discard", role: .destructive) { model.pending.removeAll() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The inline comments you haven’t submitted yet will be lost.")
                        }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(submitTitle) {
                    let body = text, ev = event, ref = model.ref, number = "\(model.provider.numberPrefix)\(pr.number)"
                    Task {
                        guard await model.submitReview(event: ev, body: body) else { return }
                        dismiss()
                        switch ev {
                        case "APPROVE": app.showToast("Approved \(number)", kind: .approved, action: app.nextReviewAction(after: ref))
                        case "REQUEST_CHANGES": app.showToast("Requested changes on \(number)", action: app.nextReviewAction(after: ref))
                        default: app.showToast("Review submitted on \(number)")
                        }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(verdictTint)
                .help("Submit (⌘↩)")
                .disabled(model.busy || disabledReason != nil)
            }
        }
    }

    private var verdictTint: Color {
        switch event {
        case "APPROVE": return .syGreenFill
        case "REQUEST_CHANGES": return .syRedFill
        default: return .syAccentFill
        }
    }

    private var submitTitle: String {
        switch event {
        case "APPROVE": return model.pending.isEmpty ? "Approve" : "Approve with \(plural(model.pending.count, "comment", "comments"))"
        case "REQUEST_CHANGES": return "Request changes"
        default: return model.pending.isEmpty ? "Comment" : "Submit \(plural(model.pending.count, "comment", "comments"))"
        }
    }

    private var disabledReason: String? {
        guard event != "APPROVE", text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.pending.isEmpty else { return nil }
        return event == "REQUEST_CHANGES" ? "Explain what needs to change to request changes." : "Write a summary or add inline comments to submit."
    }
}

struct MergeSheet: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    private var usesQueue: Bool {
        model.features.mergeQueue && pr.isMergeQueueEnabled == true && pr.mergeQueueEntry == nil
    }
    @State private var method: MergeMethod = .MERGE
    @State private var title = ""
    @State private var message = ""
    @State private var deleteBranch = true
    @State private var confirmMerge: Bool?

    private enum Gate {
        case clean, waiting, conflicts, behind, blocked
    }

    private var allowed: [MergeMethod] {
        guard let r = model.repo else { return MergeMethod.allCases }
        return MergeMethod.allCases.filter {
            switch $0 {
            case .MERGE: return r.mergeCommitAllowed
            case .SQUASH: return r.squashMergeAllowed
            case .REBASE: return r.rebaseMergeAllowed
            }
        }
    }

    private var gate: Gate {
        let reqs = model.requirements
        if reqs.contains(where: { $0.kind == .conflicts && $0.state == .missing }) { return .conflicts }
        if reqs.contains(where: { $0.kind == .behind && $0.state == .missing }) { return .behind }
        if reqs.contains(where: { $0.state == .missing }) { return .blocked }
        if reqs.contains(where: { $0.state == .pending }) || pr.mergeStateStatus == "UNSTABLE" && pr.checks.contains(where: { $0.outcome == .pending }) { return .waiting }
        return .clean
    }

    private var canAutoMerge: Bool {
        model.repo?.autoMergeAllowed == true && pr.autoMergeRequest == nil && pr.mergeStateStatus != "CLEAN"
    }

    private var deletesBranch: Bool {
        deleteBranch && !(model.repo?.deleteBranchOnMerge ?? false) && pr.headRepository?.nameWithOwner == model.ref.repo.full
    }

    var body: some View {
        let readiness = MergeStatusBar.status(pr, requirements: model.requirements)
        let gate = gate
        SheetFrame(title: "Merge \(model.provider.numberPrefix)\(pr.number) into \(pr.baseRefName)", model: model) {
            HStack(spacing: 10) {
                PullYardLogoMark(progress: 1, size: 30)
                    .saturation(gate == .clean ? 1 : 0.35)
                Text(readiness.text)
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(gate == .clean ? Color.syText : readiness.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.m + 2)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.m).fill((gate == .clean ? Color.syGreen : readiness.color).opacity(Tint.banner)))
            if usesQueue {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").foregroundStyle(Color.syMuted)
                    Text("\(pr.baseRefName) uses a \(model.features.queueTitle). Add the \(model.provider.requestTitle) to it and it merges once the required checks pass; merging directly may be rejected.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !model.requirements.isEmpty {
                ScrollView {
                    MergeRequirementsList(requirements: model.requirements, canPerform: canPerform, perform: perform, agentFix: agentFix)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
            }
            if allowed.count > 1 {
                Picker("Method", selection: $method) {
                    ForEach(allowed) { m in Label(m.short, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .tint(Color.syAccentFill)
                .onChange(of: method) { _, m in prefill(m) }
                .accessibilityLabel("Merge method")
            }
            if method != .REBASE {
                TextField("Commit title (\(model.features.serviceTitle) default)", text: $title)
                ComposerBox(text: $message, placeholder: "Commit description (optional)", minHeight: 80)
                    .frame(maxHeight: 160)
            }
            if !(model.repo?.deleteBranchOnMerge ?? false), pr.headRepository?.nameWithOwner == model.ref.repo.full {
                Toggle("Delete branch \(pr.headRefName) after merge", isOn: $deleteBranch)
            }
            HStack {
                secondaryButton(gate)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                primaryButton(gate)
            }
        }
        .onAppear {
            let def = MergeMethod(rawValue: model.repo?.viewerDefaultMergeMethod ?? "MERGE") ?? .MERGE
            method = allowed.contains(def) ? def : (allowed.first ?? .MERGE)
            prefill(method)
        }
        .onLiveTick { await model.load(live: true) }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmMerge != nil }, set: { if !$0 { confirmMerge = nil } }), titleVisibility: .visible) {
            Button(confirmMerge == true ? "Merge anyway" : "Merge", role: confirmMerge == true ? .destructive : nil) {
                confirmMerge = nil
                performMerge()
            }
            Button("Cancel", role: .cancel) { confirmMerge = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        "\(method.title) \(model.provider.numberPrefix)\(pr.number) into \(pr.baseRefName)?"
    }

    private var confirmMessage: String {
        var parts: [String] = []
        if confirmMerge == true { parts.append("Not everything required for merging is done. \(model.features.serviceTitle) may reject the merge.") }
        if deletesBranch { parts.append("The branch \(pr.headRefName) will be deleted afterwards. You can restore it from the confirmation.") }
        parts.append("This can't be undone on \(model.features.serviceTitle).")
        return parts.joined(separator: " ")
    }

    private func mergeNow() {
        confirmMerge = gate != .clean
    }

    private var autoMergeHelp: String {
        model.provider == .gitlab ? "Merge automatically when the pipeline succeeds" : "Merge automatically when checks and reviews pass"
    }

    private var canUpdateBranch: Bool {
        model.features.updateBranch && (model.canWrite || pr.viewerCanUpdate)
    }

    private var resolvesLocally: Bool {
        model.features.localConflicts && MergeConflicts.applies(pr)
    }

    private func enqueue() {
        Task {
            guard await model.simple(.enqueue) else { return }
            app.showToast("Added to the \(model.features.queueTitle)")
            dismiss()
        }
    }

    @ViewBuilder
    private func primaryButton(_ gate: Gate) -> some View {
        if usesQueue {
            Button("Add to \(model.features.queueTitle)", action: enqueue)
                .buttonStyle(.borderedProminent)
                .tint(Color.syGreenFill)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
        } else {
            gatedPrimaryButton(gate)
        }
    }

    @ViewBuilder
    private func gatedPrimaryButton(_ gate: Gate) -> some View {
        switch gate {
        case .clean:
            Button("Merge…", action: mergeNow)
                .buttonStyle(.borderedProminent)
                .tint(Color.syGreenFill)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || allowed.isEmpty)
        case .waiting where canAutoMerge:
            Button("Merge when ready", action: enableAuto)
                .buttonStyle(.borderedProminent)
                .tint(Color.syGreenFill)
                .keyboardShortcut(.defaultAction)
                .help(autoMergeHelp)
                .disabled(model.busy)
        case .conflicts where resolvesLocally:
            Button("Resolve with agent…") {
                dismiss()
                model.showResolveConflicts = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.syAgentFill)
            .keyboardShortcut(.defaultAction)
        case .behind where canUpdateBranch:
            Button(model.features.updateBranchTitle) { perform(.updateBranch) }
                .buttonStyle(.borderedProminent)
                .tint(Color.syAccentFill)
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy)
        default:
            mergeAnywayButton
        }
    }

    @ViewBuilder
    private func secondaryButton(_ gate: Gate) -> some View {
        if usesQueue {
            Button("Merge directly…", action: mergeNow)
                .buttonStyle(.bordered)
                .help("\(model.features.serviceTitle) may reject merging around the \(model.features.queueTitle)")
                .disabled(model.busy || allowed.isEmpty)
        } else {
            switch gate {
            case .clean:
                if canAutoMerge {
                    Button("Merge when ready", action: enableAuto)
                        .help(autoMergeHelp)
                }
            case .waiting where canAutoMerge, .conflicts where resolvesLocally, .behind where canUpdateBranch:
                mergeAnywayButton
            default:
                if canAutoMerge {
                    Button("Merge when ready", action: enableAuto)
                        .help(autoMergeHelp)
                }
            }
        }
    }

    private var mergeAnywayButton: some View {
        Button("Merge anyway…", action: mergeNow)
            .buttonStyle(.bordered)
            .foregroundStyle(Color.syRed)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.syRed.opacity(0.6)))
            .help("\(model.features.serviceTitle) may reject this merge")
            .disabled(model.busy || allowed.isEmpty)
    }

    private func canPerform(_ action: RequirementAction) -> Bool {
        switch action {
        case .updateBranch: return canUpdateBranch
        case .readyForReview: return model.features.draftToggle && pr.viewerCanUpdate
        case .requestReview, .showChecks, .showConversation, .showConflicts: return false
        }
    }

    private func perform(_ action: RequirementAction) {
        switch action {
        case .updateBranch:
            Task { if await model.simple(.updateBranch) { app.showToast("Branch updated from \(pr.baseRefName)") } }
        case .readyForReview:
            Task { if await model.simple(.readyForReview) { app.showToast("Marked ready for review") } }
        default:
            break
        }
    }

    private func agentFix(_ kind: RequirementKind) -> (() -> Void)? {
        guard kind == .conflicts, resolvesLocally else { return nil }
        return {
            dismiss()
            model.showResolveConflicts = true
        }
    }

    private func enableAuto() {
        let m = method.rawValue
        Task {
            guard await model.enableAutoMerge(method: m) else { return }
            dismiss()
            app.showToast("Auto-merge enabled for \(model.provider.numberPrefix)\(pr.number)")
        }
    }

    private func performMerge() {
        let t = title.trimmingCharacters(in: .whitespaces)
        let b = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let del = deletesBranch
        let number = "\(model.provider.numberPrefix)\(pr.number)", base = pr.baseRefName, branch = pr.headRefName, sha = pr.headRefOid, ref = model.ref
        let headRepo = pr.headRepository?.nameWithOwner
        Task {
            guard await model.merge(method: method.rawValue, title: t.isEmpty ? nil : t, body: b.isEmpty ? nil : b, deleteBranch: del) else { return }
            let deleted = del && model.deferredError == nil
            dismiss()
            if deleted, let headRepo, model.api != nil {
                app.showToast("Merged \(number) into \(base)", kind: .merged, action: ToastAction(title: "Restore branch") {
                    Task {
                        if await model.restoreBranch(branch, repo: headRepo, sha: sha) { app.showToast("Restored branch \(branch)") }
                    }
                })
            } else {
                app.showToast("Merged \(number) into \(base)", kind: .merged, action: app.nextReviewAction(after: ref))
            }
        }
    }

    private func prefill(_ m: MergeMethod) {
        switch m {
        case .SQUASH: title = model.provider.isGitHub ? "\(pr.title) (#\(pr.number))" : pr.title
        case .MERGE: title = ""
        case .REBASE: title = ""
        }
    }
}

struct EditPRSheet: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        SheetFrame(title: "Edit \(model.provider.numberPrefix)\(pr.number)", model: model) {
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            ComposerBox(text: $text, placeholder: "Description (Markdown)", minHeight: 260)
                .frame(maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = title, b = text
                    Task { if await model.edit(title: t, body: b) { dismiss() } }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }
        .frame(width: 680)
        .onAppear {
            title = pr.title
            text = pr.body
        }
    }
}

struct ReviewersSheet: View {
    let model: PRDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var logins = ""
    @State private var selected: Set<String> = []
    @State private var load: [String: Int] = [:]

    private var candidates: [PRReviewer] {
        model.reviewers.filter { $0.login != model.viewerLogin && !$0.login.hasSuffix("[bot]") && ($0.isTeam || !$0.login.contains("/")) }
    }

    private var typed: [String] {
        logins.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) }.filter { !$0.isEmpty }
    }

    private var ownerSuggestions: [OwnerEntry] {
        var exclude = Set(candidates.map { $0.login.lowercased() })
        exclude.insert(model.viewerLogin.lowercased())
        if let author = model.pr?.author?.login { exclude.insert(author.lowercased()) }
        return model.ownership?.suggestions(excluding: exclude) ?? []
    }

    private var requested: [String] {
        var seen = Set<String>()
        let picked = candidates.map(\.login) + ownerSuggestions.map(\.handle)
        return (picked.filter(selected.contains) + typed).filter { seen.insert($0).inserted }
    }

    var body: some View {
        SheetFrame(title: "Request review", model: model) {
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reviewers on this pull request").font(.syCaption).foregroundStyle(Color.syMuted)
                    ForEach(candidates, id: \.login) { r in
                        Toggle(isOn: Binding(get: { selected.contains(r.login) }, set: { if $0 { selected.insert(r.login) } else { selected.remove(r.login) } })) {
                            HStack(spacing: 6) {
                                ReviewerBadge(login: r.login, avatar: r.avatar, state: r.state)
                                Text(r.login)
                                if r.isTeam {
                                    Text("team").font(.syCaption).foregroundStyle(Color.syMuted)
                                }
                                if r.codeOwner {
                                    Text("code owner").font(.syCaption).foregroundStyle(Color.syViolet)
                                }
                                loadLabel(r.login)
                                if model.reviewersToReRequest.contains(r.login) {
                                    Text("reviewed before latest push").font(.syCaption).foregroundStyle(Color.syAmber)
                                } else if r.state == "PENDING" {
                                    Text("already requested").font(.syCaption).foregroundStyle(Color.syMuted)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if !ownerSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Code owners of changed files").font(.syCaption).foregroundStyle(Color.syMuted)
                    ForEach(ownerSuggestions, id: \.handle) { o in
                        Toggle(isOn: Binding(get: { selected.contains(o.handle) }, set: { if $0 { selected.insert(o.handle) } else { selected.remove(o.handle) } })) {
                            HStack(spacing: 6) {
                                Text(o.handle)
                                if o.isTeam {
                                    Text("team").font(.syCaption).foregroundStyle(Color.syMuted)
                                }
                                Text("not requested").font(.syCaption).foregroundStyle(Color.syMuted)
                                loadLabel(o.handle)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            TextField("Other logins or teams, comma-separated, e.g. alice, org/team", text: $logins).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(requested.isEmpty ? "Request" : "Request (\(requested.count))") {
                    let list = requested
                    Task { if await model.requestReviewers(list) { dismiss() } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(requested.isEmpty || model.busy)
            }
        }
        .onAppear { selected = Set(model.reviewersToReRequest) }
        .task {
            guard let api = model.api else { return }
            load = await ReviewLoadStore.shared.load(candidates.map(\.login) + ownerSuggestions.map(\.handle), api: api)
        }
    }

    @ViewBuilder
    private func loadLabel(_ handle: String) -> some View {
        if let n = load[handle.lowercased()] {
            Text("· " + ReviewLoad.label(n))
                .font(.syCaption.monospacedDigit())
                .foregroundStyle(ReviewLoad.busy(n) ? Color.syAmber : Color.syDim)
                .help("Open pull requests waiting for \(handle)'s review, among those you can see")
        }
    }
}

struct ReplySheet: View {
    let model: PRDetailModel
    let thread: ReviewThread
    @Environment(\.dismiss) private var dismiss

    private var text: String { model.replyDrafts[thread.id] ?? "" }

    private var draft: Binding<String> {
        Binding(get: { model.replyDrafts[thread.id] ?? "" }, set: { model.replyDrafts[thread.id] = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        SheetFrame(title: "Reply to thread", model: model) {
            Text("\(thread.path)\(thread.line.map { ":\($0)" } ?? "")").font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
            if let last = thread.comments.nodes.last {
                HStack(alignment: .top, spacing: 8) {
                    Avatar(url: last.author?.avatarUrl, size: 18)
                    MarkdownText(text: last.body).lineLimit(6).font(.syCallout)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            }
            ComposerBox(text: draft, placeholder: "Reply (Markdown)", minHeight: 120).frame(maxHeight: 240)
            HStack {
                if thread.viewerCanResolve, !thread.isResolved {
                    Button("Reply and resolve") { send(resolve: true) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reply") { send(resolve: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
        }
    }

    private func send(resolve: Bool) {
        let body = text
        let id = thread.id
        Task {
            if await model.reply(id, body: body) {
                model.replyDrafts[id] = nil
                if resolve { await model.setResolved(id, true) }
                dismiss()
            }
        }
    }
}

struct JobLogSheet: View {
    let load: () async throws -> String
    let check: CheckContext
    var onFix: ((String?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var log: String?
    @State private var error: String?
    @State private var errorsOnly = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                OutcomeIcon(outcome: check.outcome)
                Text(check.workflowName.map { "\($0) / \(check.title)" } ?? check.title).font(.syHeadline).lineLimit(1)
                Spacer()
                Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                if let log { Button("Copy") { copyToPasteboard(log) } }
                if let link = check.link { Button("Open in browser") { openInBrowser(link) } }
                if let onFix {
                    Button("Fix with agent") { onFix(log) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.syCoralFill)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let log {
                LogTextView(text: errorsOnly ? filterErrors(log) : log)
            } else if let error {
                ErrorStateView(message: error)
            } else {
                LoadingView()
            }
        }
        .frame(width: 980, height: 640)
        .task {
            do {
                let raw = try await load()
                log = await Task.detached { Self.clean(raw) }.value
            } catch {
                if isCancellation(error) { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func filterErrors(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n")
        var keep: [String] = []
        for (i, l) in lines.enumerated() where l.contains("##[error]") || l.localizedCaseInsensitiveContains("error") || l.contains("FAILED") || l.contains("✗") {
            let from = max(0, i - 3)
            if let last = keep.last, last == "…" {} else if !keep.isEmpty { keep.append("…") }
            keep += lines[from...i]
        }
        return keep.isEmpty ? "No error lines found" : keep.joined(separator: "\n")
    }

    nonisolated static func clean(_ raw: String) -> String {
        CILogExcerpt.clean(raw)
    }
}

struct LogTextView: NSViewRepresentable {
    let text: String
    var zoom = TextZoom.shared.scale

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = font
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.isAutomaticSpellingCorrectionEnabled = false
        set(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, tv.string != text || tv.font?.pointSize != font.pointSize else { return }
        tv.font = font
        set(tv)
    }

    private var font: NSFont { .monospacedSystemFont(ofSize: TextZoom.size(11, at: zoom), weight: .regular) }

    private func set(_ tv: NSTextView) {
        let attr = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, range, _, _ in
            guard let sub else { return }
            if sub.contains("##[error]") { attr.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range) }
            else if sub.contains("##[warning]") { attr.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range) }
            else if sub.hasPrefix("##[group]") { attr.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range) }
        }
        let clip = tv.enclosingScrollView?.contentView
        let atEnd = clip.map { $0.bounds.maxY >= tv.frame.height - 24 } ?? true
        tv.textStorage?.setAttributedString(attr)
        if atEnd { tv.scrollToEndOfDocument(nil) }
    }
}
