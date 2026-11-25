import SwiftUI

enum StackPlan {
    static func updateOrder(_ tree: StackTree) -> [Int] {
        var out: [Int] = []
        var queue = [tree.root]
        var i = 0
        while i < queue.count {
            let x = queue[i]
            i += 1
            if let node = tree.nodes[x], node.state == "OPEN" { out.append(x) }
            queue += tree.children[x] ?? []
        }
        return out
    }

    static func mergeable(_ tree: StackTree) -> StackNode? {
        guard let node = tree.nodes[tree.root], node.state == "OPEN", !node.isDraft, node.baseRefName == tree.base else { return nil }
        return node
    }

    static func retargets(afterMerging tree: StackTree) -> [Int] {
        (tree.children[tree.root] ?? []).filter { tree.nodes[$0]?.state == "OPEN" }
    }
}

enum StackOperation: Equatable {
    case updateAll
    case mergeBottom(method: String)
}

@Observable
@MainActor
final class StackActionRun {
    enum StepState: Equatable {
        case waiting, running, done, skipped(String), failed(String)
    }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var state: StepState = .waiting
    }

    let operation: StackOperation
    private(set) var steps: [Step] = []
    private(set) var running = false
    private(set) var finished = false

    init(operation: StackOperation, tree: StackTree) {
        self.operation = operation
        switch operation {
        case .updateAll:
            steps = StackPlan.updateOrder(tree).map { Step(id: "update-\($0)", title: "Update #\($0) from \(tree.nodes[$0]?.baseRefName ?? "base")") }
        case .mergeBottom:
            guard let bottom = StackPlan.mergeable(tree) else { return }
            steps = [Step(id: "merge-\(bottom.number)", title: "Merge #\(bottom.number) into \(tree.base)")]
            steps += StackPlan.retargets(afterMerging: tree).map { Step(id: "retarget-\($0)", title: "Point #\($0) at \(tree.base)") }
            steps += StackPlan.retargets(afterMerging: tree).map { Step(id: "update-\($0)", title: "Update #\($0) from \(tree.base)") }
        }
    }

    var failed: Bool { steps.contains { if case .failed = $0.state { return true } else { return false } } }

    func run(api: GitHubAPI, repo: RepoRef, base: String) async {
        guard !running, !finished else { return }
        running = true
        defer {
            running = false
            finished = true
        }
        let method: String? = { if case .mergeBottom(let m) = operation { return m } else { return nil } }()
        for index in steps.indices {
            if failed {
                steps[index].state = .skipped("Stopped after an error")
                continue
            }
            steps[index].state = .running
            let parts = steps[index].id.split(separator: "-")
            guard parts.count == 2, let number = Int(parts[1]) else { continue }
            let path = "/repos/\(repo.full)/pulls/\(number)"
            do {
                switch parts[0] {
                case "merge":
                    try await api.send("PUT", path + "/merge", body: ["merge_method": (method ?? "SQUASH").lowercased()])
                case "retarget":
                    try await api.send("PATCH", path, body: ["base": base])
                default:
                    let before = try? await head(api, path)
                    do {
                        try await api.send("PUT", path + "/update-branch", body: [:])
                    } catch let e as APIError where e.status == 422 {
                        steps[index].state = .skipped(e.message.lowercased().contains("up to date") || e.message.lowercased().contains("no new commits") ? "Already up to date" : e.message)
                        continue
                    }
                    await waitForNewHead(api, path, from: before)
                }
                steps[index].state = .done
            } catch {
                steps[index].state = .failed(error.localizedDescription)
            }
        }
    }

    private struct PRHead: Decodable {
        struct Ref: Decodable { let sha: String }
        let head: Ref
    }

    private func head(_ api: GitHubAPI, _ path: String) async throws -> String {
        let pr: PRHead = try await api.rest("GET", path)
        return pr.head.sha
    }

    private func waitForNewHead(_ api: GitHubAPI, _ path: String, from before: String?) async {
        guard let before else { return }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(750))
            if let now = try? await head(api, path), now != before { return }
        }
    }
}

struct StackActionsMenu: View {
    let tree: StackTree
    let start: (StackOperation) -> Void

    var body: some View {
        Menu {
            Button("Update All Branches") { start(.updateAll) }
                .disabled(StackPlan.updateOrder(tree).isEmpty)
            if let bottom = StackPlan.mergeable(tree) {
                Section("Merge #\(bottom.number) and point the next ones at \(tree.base)") {
                    Button("Squash and Merge…") { start(.mergeBottom(method: "SQUASH")) }
                    Button("Create a Merge Commit…") { start(.mergeBottom(method: "MERGE")) }
                    Button("Rebase and Merge…") { start(.mergeBottom(method: "REBASE")) }
                }
            }
        } label: {
            Label("Stack actions", systemImage: "square.stack.3d.up.fill")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Update every branch in the stack, or merge the bottom pull request and move the rest onto \(tree.base)")
    }
}

struct StackActionCard: View {
    let run: StackActionRun
    let tree: StackTree
    let confirm: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconTile(systemImage: icon, color: tint, size: 24)
                Text(title).font(.syHeadline).foregroundStyle(Color.syText)
                Spacer()
                if !run.running {
                    Button(action: close) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.syMuted)
                        .help("Close")
                        .accessibilityLabel("Close")
                }
            }
            if !run.running && !run.finished {
                Text(explanation).font(.syCallout).foregroundStyle(Color.syMuted).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(run.steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        stepIcon(step.state).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.syCallout).foregroundStyle(Color.syText)
                            if let note = note(step.state) {
                                Text(note).font(.syCaption).foregroundStyle(isFailure(step.state) ? Color.syRed : Color.syMuted).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            if !run.running && !run.finished {
                HStack {
                    Spacer()
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: confirm)
                        .buttonStyle(.borderedProminent)
                        .tint(isMerge ? Color.syGreenFill : Color.syAccentFill)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            } else if run.finished {
                Text(run.failed ? "Stopped. Nothing after the failed step was changed." : "Done. The stack reloads with the new state.")
                    .font(.syCaption)
                    .foregroundStyle(run.failed ? Color.syRed : Color.syMuted)
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .pyGlass(in: RoundedRectangle(cornerRadius: 14), fallback: Color.syRaised)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.syLineStrong))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }

    private var isMerge: Bool { if case .mergeBottom = run.operation { return true } else { return false } }
    private var icon: String { isMerge ? "arrow.triangle.merge" : "arrow.triangle.2.circlepath" }
    private var tint: Color { isMerge ? .syGreen : .sySky }
    private var title: String { isMerge ? "Merge the bottom of the stack" : "Update the stack" }

    private var confirmTitle: String {
        guard case .mergeBottom(let method) = run.operation else { return "Update \(plural(run.steps.count, "branch", "branches"))" }
        switch method {
        case "MERGE": return "Merge #\(tree.root)"
        case "REBASE": return "Rebase and merge #\(tree.root)"
        default: return "Squash and merge #\(tree.root)"
        }
    }

    private var explanation: String {
        if isMerge {
            return "Merges #\(tree.root) into \(tree.base), then points the pull requests on top of it at \(tree.base) and brings them up to date. The branch of #\(tree.root) is kept."
        }
        return "Brings each branch up to date with the one below it, from the bottom of the stack up. GitHub adds a merge commit where a branch is behind."
    }

    @ViewBuilder
    private func stepIcon(_ state: StackActionRun.StepState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(Color.syDim)
        case .running: WakeLoader()
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.syGreen)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Color.syMuted)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syRed)
        }
    }

    private func note(_ state: StackActionRun.StepState) -> String? {
        switch state {
        case .skipped(let s), .failed(let s): return s
        default: return nil
        }
    }

    private func isFailure(_ state: StackActionRun.StepState) -> Bool {
        if case .failed = state { return true } else { return false }
    }
}

struct StackSupportCard: View {
    let buy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("🍕").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 4) {
                Text("Like the stack graph?").font(.syHeadline).foregroundStyle(Color.syText)
                Text("PullYard is free and built by one developer. If it saves you time, a pizza keeps it going. We only ask once.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Buy a Pizza", action: buy).buttonStyle(.borderedProminent).tint(Color.syAccentFill)
                    Button("No thanks", action: dismiss)
                }
                .controlSize(.small)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .pyGlass(in: RoundedRectangle(cornerRadius: 14), fallback: Color.syRaised)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.syLineStrong))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}
