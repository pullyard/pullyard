import SwiftUI

struct ReviewPanel: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var event = "COMMENT"

    private var text: String { model.summaryDraft }

    private var grouped: [(path: String, comments: [PendingComment])] {
        var order: [String] = []
        var map: [String: [PendingComment]] = [:]
        for c in model.pending {
            if map[c.path] == nil { order.append(c.path) }
            map[c.path, default: []].append(c)
        }
        return order.map { ($0, (map[$0] ?? []).sorted { $0.line < $1.line }) }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.syLine).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progress
                    if !pr.viewerDidAuthor {
                        Picker("Verdict", selection: $event) {
                            Text("Comment").tag("COMMENT")
                            Text("Approve").tag("APPROVE")
                            Text("Changes").tag("REQUEST_CHANGES")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .tint(verdictTint)
                    }
                    ComposerBox(text: $model.summaryDraft, placeholder: event == "APPROVE" ? "Summary (optional)" : "Review summary", minHeight: 110)
                        .frame(maxHeight: 220)
                    pendingList
                }
                .padding(16)
            }
            Rectangle().fill(Color.syLine).frame(height: 1)
            footer
        }
        .background(Color.syPanel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Review #\(pr.number)")
                .font(.system(size: TextZoom.shared.size(16), weight: .semibold, design: .serif))
                .foregroundStyle(Color.syText)
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.syIcon(10)).frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.syMuted)
            .help("Close the review panel")
            .accessibilityLabel("Close review panel")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .pyGlass(in: Rectangle(), fallback: Color.syBar, outline: false)
    }

    private var progress: some View {
        let total = model.displayedFiles.count
        let viewed = model.viewedPaths.intersection(model.displayedFiles.map(\.id)).count
        let unresolved = pr.reviewThreads.nodes.filter { !$0.isResolved && !$0.isOutdated }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(model.filesLoaded ? "\(viewed)/\(total) files viewed" : "Files not loaded yet")
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syText)
                Spacer()
                if unresolved > 0 {
                    StatusChip(text: "\(unresolved) unresolved", icon: "text.bubble", color: .syAmberInk)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.syLineStrong)
                    Capsule().fill(Color.syCoral).frame(width: total > 0 ? geo.size.width * CGFloat(viewed) / CGFloat(total) : 0)
                }
            }
            .frame(height: 5)
            .animation(Motion.gentle, value: viewed)
            if model.filesLoaded, viewed < total {
                Button("Next unviewed file") {
                    if let next = model.displayedFiles.first(where: { !model.viewedPaths.contains($0.id) }) {
                        model.tab = .files
                        model.revealFile(next.id)
                    }
                }
                .buttonStyle(.link)
                .font(.syCaption)
            }
        }
    }

    @ViewBuilder
    private var pendingList: some View {
        if model.pending.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(Color.syDim)
                Text("Inline comments you add in Files collect here until you submit.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(plural(model.pending.count, "pending comment", "pending comments"))
                    .font(.sy(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Color.syMuted)
                ForEach(grouped, id: \.path) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            model.tab = .files
                            model.revealFile(group.path)
                        } label: {
                            Label((group.path as NSString).lastPathComponent, systemImage: "doc.text")
                                .font(.syCaption.weight(.semibold).monospaced())
                                .foregroundStyle(Color.syLink)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help(group.path)
                        ForEach(group.comments) { c in
                            HStack(alignment: .top, spacing: 6) {
                                Text("L\(c.line)")
                                    .font(.syCaption2.monospacedDigit())
                                    .foregroundStyle(Color.syDim)
                                    .frame(width: 34, alignment: .leading)
                                Text(c.body)
                                    .font(.syCaption)
                                    .foregroundStyle(Color.syText)
                                    .lineLimit(3)
                                Spacer(minLength: 4)
                                Button {
                                    model.pending.removeAll { $0.id == c.id }
                                } label: {
                                    Image(systemName: "trash").font(.syIcon(9))
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.syDim)
                                .help("Remove this pending comment")
                                .accessibilityLabel("Remove comment")
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = disabledReason {
                Text(reason).font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Button {
                submit()
            } label: {
                Text(submitTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(verdictTint)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.busy || disabledReason != nil)
        }
        .padding(16)
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

    private func submit() {
        let body = text, ev = event, ref = model.ref, number = pr.number
        Task {
            guard await model.submitReview(event: ev, body: body) else { return }
            close()
            switch ev {
            case "APPROVE": app.showToast("Approved #\(number)", kind: .approved, action: app.nextReviewAction(after: ref))
            case "REQUEST_CHANGES": app.showToast("Requested changes on #\(number)", action: app.nextReviewAction(after: ref))
            default: app.showToast("Review submitted on #\(number)")
            }
        }
    }
}
