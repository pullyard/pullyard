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
    @State private var text = ""
    @State private var event = "COMMENT"
    @State private var confirmDiscard = false

    var body: some View {
        SheetFrame(title: "Review #\(pr.number)", model: model) {
            if !model.pending.isEmpty {
                Label("Inline comments to be submitted: \(model.pending.count)", systemImage: "text.bubble")
                    .foregroundStyle(Color.syMuted)
            }
            ComposerBox(text: $text, placeholder: "Review summary (optional when approving)", minHeight: 140)
                .frame(maxHeight: 260)
            Picker("", selection: $event) {
                Text("Comment — without approval").tag("COMMENT")
                Text("Approve").tag("APPROVE").disabled(pr.viewerDidAuthor)
                Text("Request changes").tag("REQUEST_CHANGES").disabled(pr.viewerDidAuthor)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
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
                Button("Submit review") {
                    let body = text, ev = event
                    Task { if await model.submitReview(event: ev, body: body) { dismiss() } }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || (event != "APPROVE" && text.trimmingCharacters(in: .whitespaces).isEmpty && model.pending.isEmpty))
            }
        }
    }
}

struct MergeSheet: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    @Environment(\.dismiss) private var dismiss
    @State private var method: MergeMethod = .MERGE
    @State private var title = ""
    @State private var message = ""
    @State private var deleteBranch = true

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

    var body: some View {
        let readiness = MergeStatusBar.status(pr, requirements: model.requirements)
        let blocked = !readiness.ready && pr.mergeStateStatus != nil && pr.mergeStateStatus != "UNKNOWN"
        SheetFrame(title: "Merge #\(pr.number) into \(pr.baseRefName)", model: model) {
            Label(readiness.text, systemImage: readiness.icon)
                .font(.syCallout)
                .foregroundStyle(readiness.ready ? Color.syText : readiness.color)
                .padding(.horizontal, Space.m + 2)
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.m).fill(readiness.color.opacity(Tint.banner)))
            Picker("Method", selection: $method) {
                ForEach(allowed) { Text($0.title).tag($0) }
            }
            .onChange(of: method) { _, m in prefill(m) }
            if method != .REBASE {
                TextField("Commit title (GitHub default)", text: $title)
                ComposerBox(text: $message, placeholder: "Commit description (optional)", minHeight: 80)
                    .frame(maxHeight: 160)
            }
            if !(model.repo?.deleteBranchOnMerge ?? false), pr.headRepository?.nameWithOwner == model.ref.repo.full {
                Toggle("Delete branch \(pr.headRefName) after merge", isOn: $deleteBranch)
            }
            HStack {
                if model.repo?.autoMergeAllowed == true, pr.autoMergeRequest == nil, pr.mergeStateStatus != "CLEAN" {
                    Button("Enable auto-merge") {
                        Task { if await model.enableAutoMerge(method: method.rawValue) { dismiss() } }
                    }
                    .help("Merge automatically when checks and reviews pass")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(blocked ? "Merge anyway" : "Merge") {
                    let t = title.trimmingCharacters(in: .whitespaces)
                    let b = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    let del = deleteBranch && !(model.repo?.deleteBranchOnMerge ?? false) && pr.headRepository?.nameWithOwner == model.ref.repo.full
                    Task {
                        if await model.merge(method: method.rawValue, title: t.isEmpty ? nil : t, body: b.isEmpty ? nil : b, deleteBranch: del) { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(blocked ? Color.syRedFill : Color.syGreenFill)
                .help(blocked ? "GitHub may reject this merge: \(readiness.text)" : "Merge pull request")
                .disabled(model.busy || allowed.isEmpty)
            }
        }
        .onAppear {
            let def = MergeMethod(rawValue: model.repo?.viewerDefaultMergeMethod ?? "MERGE") ?? .MERGE
            method = allowed.contains(def) ? def : (allowed.first ?? .MERGE)
            prefill(method)
        }
    }

    private func prefill(_ m: MergeMethod) {
        switch m {
        case .SQUASH: title = "\(pr.title) (#\(pr.number))"
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
        SheetFrame(title: "Edit #\(pr.number)", model: model) {
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
    }
}

struct ReplySheet: View {
    let model: PRDetailModel
    let thread: ReviewThread
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

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
            ComposerBox(text: $text, placeholder: "Reply (Markdown)", minHeight: 120).frame(maxHeight: 240)
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
                if resolve { await model.setResolved(id, true) }
                dismiss()
            }
        }
    }
}

struct JobLogSheet: View {
    let api: GitHubAPI
    let repo: RepoRef
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
                        .tint(Color.syCoral)
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
            guard let id = check.databaseId else {
                error = "This check has no job log. Open it on GitHub to see its output."
                return
            }
            do {
                let raw = try await api.jobLog(repo: repo, jobId: id)
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
