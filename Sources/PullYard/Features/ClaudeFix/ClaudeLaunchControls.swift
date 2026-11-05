import SwiftUI

extension ClaudeLauncher {
    @MainActor
    @discardableResult
    static func start(app: AppModel, prompt: String, folder: String?, target: ClaudeTarget, mode: ClaudePermissionMode, name: String) throws -> ClaudeTab? {
        if target == .app, let folder {
            let tab = app.claude.newSession(folder: folder, prompt: prompt, name: name)
            app.section = .claude
            return tab
        }
        try launch(prompt: prompt, folder: folder ?? "", target: target, mode: mode, sessionName: name, configDir: ClaudeProfiles.shared.activeOverride)
        return nil
    }
}

struct ClaudeFolderRow: View {
    let repo: RepoRef
    @Binding var folder: String?
    let detecting: Bool

    private var folderMatches: Bool {
        guard let folder else { return false }
        return LocalRepoStore.remoteMatches(folder, repo: repo)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Color.syTeal)
            if detecting {
                ProgressView().controlSize(.small)
                Text("Looking for a local clone of \(repo.full)…").font(.syCallout).foregroundStyle(Color.syMuted)
            } else if let folder {
                Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.syCallout.monospaced())
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !folderMatches {
                    Label("remote doesn't match \(repo.full)", systemImage: "exclamationmark.triangle.fill")
                        .font(.syCaption)
                        .foregroundStyle(Color.syAmber)
                }
            } else {
                Text("No local clone found").font(.syCallout).foregroundStyle(Color.syAmber)
                Button("Copy “gh repo clone”") { copyToPasteboard("gh repo clone \(repo.full)") }
                    .buttonStyle(.link)
                    .font(.syCaption)
            }
            Spacer()
            Button("Choose folder…") {
                if let p = LocalRepoStore.choose(repo) { folder = p }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card(radius: 8)
    }
}

struct ClaudeLaunchRow: View {
    @Binding var target: ClaudeTarget
    @Binding var mode: ClaudePermissionMode
    let canLaunch: Bool
    let onLaunch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Picker("Open in", selection: $target) {
                ForEach(ClaudeTarget.allCases.filter(\.available)) { Text($0.title).tag($0) }
            }
            .frame(width: 220)
            Picker("Mode", selection: $mode) {
                ForEach(ClaudePermissionMode.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 250)
            .disabled(target == .desktop || target == .copy || target == .app)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(target == .copy ? "Copy" : "Launch", action: onLaunch)
                .buttonStyle(.borderedProminent)
                .tint(Color.syCoral)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canLaunch)
        }
        .overlay(alignment: .topLeading) {
            if target == .desktop {
                Text("Prompt will be copied — paste it into the new session (⌘V)")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .offset(y: -18)
            }
        }
    }
}

extension ClaudeLauncher {
    @MainActor
    @discardableResult
    static func startForPR(app: AppModel, prompt: String, folder: String?, isolate: Bool, pr: PullRequestDetail, repo: RepoRef,
                           target: ClaudeTarget, mode: ClaudePermissionMode, name: String) async throws -> ClaudeTab? {
        guard isolate, target != .copy, let folder else {
            return try start(app: app, prompt: prompt, folder: folder, target: target, mode: mode, name: name)
        }
        let number = pr.number
        let worktree = try await Task.detached(priority: .userInitiated) { try PRWorktrees.prepare(clone: folder, repo: repo, number: number) }.value
        let adapted = PRWorktrees.adapt(prompt, worktree: worktree, pr: pr, repo: repo)
        return try start(app: app, prompt: adapted, folder: worktree.path, target: target, mode: mode, name: name)
    }
}

struct ClaudeWorktreeRow: View {
    let folder: String?
    let number: Int
    let target: ClaudeTarget
    @Binding var isolate: Bool
    @State private var existing: String?
    @State private var removing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Work in an isolated git worktree", isOn: $isolate)
                    .toggleStyle(.checkbox)
                    .disabled(folder == nil || target == .copy)
                    .help("PullYard checks out the pull request in a separate worktree next to your clone, so your current branch and uncommitted changes stay untouched")
                Spacer()
                if let existing {
                    Button(removing ? "Removing…" : "Remove worktree") { remove(existing) }
                        .controlSize(.small)
                        .disabled(removing)
                        .help("Delete \(existing) and its local branch. Refuses if it has uncommitted changes")
                }
            }
            if let folder, isolate, target != .copy {
                Text("\(existing == nil ? "Creates" : "Reuses") \(display(PRWorktrees.path(clone: folder, number: number))) on branch \(PRWorktrees.branch(number: number)) at the pull request head. The checkout step in the prompt is replaced when it starts.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.syCaption).foregroundStyle(Color.syRed) }
        }
        .task(id: folder) { await refresh() }
    }

    private func display(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func refresh() async {
        guard let folder else { existing = nil; return }
        let n = number
        existing = await Task.detached(priority: .utility) { PRWorktrees.existing(clone: folder, number: n) }.value
    }

    private func remove(_ path: String) {
        guard let folder else { return }
        removing = true
        error = nil
        let n = number
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PRWorktrees.remove(clone: folder, number: n) }.value
            } catch {
                self.error = error.localizedDescription
            }
            removing = false
            await refresh()
        }
    }
}
