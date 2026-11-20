import SwiftUI

struct ReviewFixLaunch: Equatable {
    let threadIDs: [String]
    let headOid: String
    let at: Date
}

enum CloseLoop {
    struct Pending: Equatable {
        let threads: [String]
        let newCommits: Int
    }

    static func pending(_ launch: ReviewFixLaunch?, pr: PullRequestDetail) -> Pending? {
        guard let launch, pr.isOpen, !pr.headRefOid.isEmpty, pr.headRefOid != launch.headOid else { return nil }
        let open = Set(pr.reviewThreads.nodes.filter { !$0.isResolved }.map(\.id))
        let threads = launch.threadIDs.filter { open.contains($0) }
        guard !threads.isEmpty else { return nil }
        let oids = pr.allCommits.nodes.map(\.commit.oid)
        let newCommits = oids.firstIndex(of: launch.headOid).map { oids.count - $0 - 1 } ?? 1
        return Pending(threads: threads, newCommits: max(newCommits, 1))
    }

    static func defaultReply(head: String) -> String {
        head.isEmpty ? "Fixed." : "Fixed in \(head.prefix(7))."
    }
}

struct CloseLoopBanner: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let onOpen: ([String]) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        if let pending = CloseLoop.pending(app.claude.reviewFixes[model.ref], pr: pr) {
            HStack(spacing: 8) {
                IconTile(systemImage: "checkmark.bubble.fill", color: .syGreen, size: 18)
                Text(plural(pending.newCommits, "new commit", "new commits") + " since Fix with agent · " + plural(pending.threads.count, "thread still open", "threads still open"))
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                Spacer()
                Button("Reply and resolve…") { onOpen(pending.threads) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.syGreenFill)
                Button { app.claude.reviewFixes[model.ref] = nil } label: { Image(systemName: "xmark").font(.syCaption2.weight(.bold)) }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
            }
            .font(.syCallout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.syGreen.opacity(0.07)))
        }
    }
}

struct CloseLoopRequest: Identifiable {
    let id = UUID()
    let preselected: [String]
}

struct CloseLoopSheet: View {
    let model: PRDetailModel
    let pr: PullRequestDetail
    let preselected: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var selected: Set<String> = []
    @State private var message = ""
    @State private var resolve = true
    @State private var working = false
    @State private var failures: [String: String] = [:]

    private var threads: [ReviewThread] {
        pr.reviewThreads.nodes.filter { !$0.isResolved && $0.viewerCanReply }
    }

    var body: some View {
        SheetFrame(title: "Reply and resolve threads", model: model) {
            Text("Posts the same reply on each selected thread\(resolve ? " and resolves it" : ""). Use it once the fixes are pushed.")
                .font(.syCallout)
                .foregroundStyle(Color.syMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Open threads").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                Spacer()
                Button("All") { selected = Set(threads.map(\.id)) }.buttonStyle(.link).font(.syCaption)
                Button("None") { selected = [] }.buttonStyle(.link).font(.syCaption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if threads.isEmpty {
                        Text("No open threads").font(.syCallout).foregroundStyle(Color.syDim)
                    }
                    ForEach(threads) { th in
                        VStack(alignment: .leading, spacing: 1) {
                            Toggle(isOn: Binding(get: { selected.contains(th.id) }, set: { on in if on { selected.insert(th.id) } else { selected.remove(th.id) } })) {
                                HStack(spacing: 6) {
                                    Text(th.path.isEmpty ? "Thread" : "\(th.path)\((th.line ?? th.originalLine).map { ":\($0)" } ?? "")")
                                        .font(.syCaption.monospaced())
                                        .foregroundStyle(Color.sySky)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                    if th.isOutdated { ChipView(text: "outdated", color: .syAmber) }
                                    Text("@\(th.comments.nodes.first?.author?.login ?? "?"): \(th.comments.nodes.first?.body.replacingOccurrences(of: "\n", with: " ") ?? "")")
                                        .font(.syCaption)
                                        .foregroundStyle(Color.syMuted)
                                        .lineLimit(1)
                                }
                            }
                            .toggleStyle(.checkbox)
                            if let error = failures[th.id] {
                                Text(error).font(.syCaption2).foregroundStyle(Color.syRed).padding(.leading, 20)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            ComposerBox(text: $message, placeholder: "Reply (Markdown)", minHeight: 56)
                .frame(maxHeight: 110)
            Toggle("Resolve the threads after replying", isOn: $resolve).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Working…" : (resolve ? "Reply and resolve \(selected.count)" : "Reply to \(selected.count)")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.syGreenFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || selected.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            let open = Set(threads.map(\.id))
            selected = Set(preselected.filter { open.contains($0) })
            if message.isEmpty { message = CloseLoop.defaultReply(head: pr.headRefOid) }
        }
    }

    private func submit() {
        let chosen = threads.filter { selected.contains($0.id) }
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        working = true
        failures = [:]
        Task {
            let result = await model.closeLoop(chosen, body: body, resolve: resolve)
            working = false
            failures = result
            selected = Set(result.keys)
            let done = chosen.count - result.count
            if done > 0 { app.showToast(resolve ? "Replied and resolved \(plural(done, "thread", "threads"))" : "Replied to \(plural(done, "thread", "threads"))") }
            if result.isEmpty {
                app.claude.reviewFixes[model.ref] = nil
                dismiss()
            }
        }
    }
}
