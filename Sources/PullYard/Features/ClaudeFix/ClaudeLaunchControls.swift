import SwiftUI

extension ClaudeLauncher {
    @MainActor
    @discardableResult
    static func start(app: AppModel, prompt: String, folder: String?, target: ClaudeTarget, mode: ClaudePermissionMode, name: String, profileID: String? = nil, environmentID: String? = nil) throws -> ClaudeTab? {
        let chosen = ClaudeProfiles.shared.profile(id: profileID)
        if target == .app, let folder {
            let tab = app.claude.newSession(folder: folder, prompt: prompt, name: name, profileID: chosen?.id, environmentID: environmentID)
            app.section = .claude
            return tab
        }
        let configDir = chosen.map { $0.configDir } ?? ClaudeProfiles.shared.activeOverride
        try launch(prompt: prompt, folder: folder ?? "", target: target, mode: mode, sessionName: name, configDir: configDir)
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
                PYLoader(size: 16)
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
    var profileID: Binding<String>? = nil
    let canLaunch: Bool
    let onLaunch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 10) {
            Picker("Open in", selection: $target) {
                ForEach(ClaudeTarget.allCases.filter(\.available)) { Text($0.title).tag($0) }
            }
            .frame(width: 200)
            if let profileID, ClaudeProfiles.shared.hasSeveral {
                Picker("Account", selection: profileID) {
                    ForEach(ClaudeProfiles.shared.visible) { p in
                        Text([AgentAccountFilter.name(p), p.email].compactMap { $0 }.joined(separator: " · ")).tag(p.id)
                    }
                }
                .frame(width: 260)
                .disabled(target == .copy)
                .help("Claude account the session runs as")
            }
            Picker("Mode", selection: $mode) {
                ForEach(ClaudePermissionMode.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 200)
            .disabled(target == .desktop || target == .copy || target == .app)
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(target == .copy ? "Copy" : "Launch", action: onLaunch)
                .buttonStyle(.borderedProminent)
                .tint(Color.syCoralFill)
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
    static func startForPR(app: AppModel, prompt: String, folder: String?, isolate: Bool, worktreePath: String? = nil, pr: PullRequestDetail, repo: RepoRef,
                           target: ClaudeTarget, mode: ClaudePermissionMode, name: String, profileID: String? = nil, environmentID: String? = nil) async throws -> ClaudeTab? {
        if let worktreePath, target != .copy {
            let note = "You are working in the git worktree `\(worktreePath)`. Run commands and edit files there.\n\n"
            return try start(app: app, prompt: note + prompt, folder: worktreePath, target: target, mode: mode, name: name, profileID: profileID, environmentID: environmentID)
        }
        guard isolate, target != .copy, let folder else {
            return try start(app: app, prompt: prompt, folder: folder, target: target, mode: mode, name: name, profileID: profileID, environmentID: environmentID)
        }
        let number = pr.number
        let worktree = try await Task.detached(priority: .userInitiated) { try PRWorktrees.prepare(clone: folder, repo: repo, number: number) }.value
        let adapted = PRWorktrees.adapt(prompt, worktree: worktree, pr: pr, repo: repo)
        return try start(app: app, prompt: adapted, folder: worktree.path, target: target, mode: mode, name: name, profileID: profileID, environmentID: environmentID)
    }
}

struct ClaudeWorktreeRow: View {
    let folder: String?
    let number: Int
    let target: ClaudeTarget
    @Binding var isolate: Bool
    /// An existing worktree of the clone the agent should work in instead; nil = isolated PR worktree or the main checkout.
    @Binding var worktreePath: String?
    @State private var existing: String?
    @State private var others: [GitWorktreeEntry] = []
    @State private var removing = false
    @State private var error: String?
    @State private var open = false

    init(folder: String?, number: Int, target: ClaudeTarget, isolate: Binding<Bool>, worktreePath: Binding<String?> = .constant(nil)) {
        self.folder = folder
        self.number = number
        self.target = target
        _isolate = isolate
        _worktreePath = worktreePath
    }

    private var enabled: Bool { folder != nil && target != .copy }

    private enum Choice: Equatable { case isolated, main, existing(GitWorktreeEntry) }

    private var choice: Choice {
        if let worktreePath, let w = others.first(where: { $0.path == worktreePath }) { return .existing(w) }
        return isolate ? .isolated : .main
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon(choice)).foregroundStyle(Color.syAgentAccent).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("WORKTREE").font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                    Text(title(choice)).font(.syCallout.weight(.medium)).foregroundStyle(Color.syText).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let existing, choice == .isolated {
                    Button(removing ? "Removing…" : "Remove worktree") { remove(existing) }
                        .controlSize(.small)
                        .disabled(removing)
                        .help("Delete \(existing) and its local branch. Refuses if it has uncommitted changes")
                }
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        Text("Change")
                        Image(systemName: "chevron.down").font(.syCaption2.weight(.semibold))
                    }
                }
                .controlSize(.small)
                .disabled(!enabled)
                .popover(isPresented: $open, arrowEdge: .bottom) { picker }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .card(radius: 8)
            if let folder, enabled {
                Text(detail(choice, folder: folder))
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.syCaption).foregroundStyle(Color.syRed) }
        }
        .task(id: folder) { await refresh() }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            option(.isolated)
            option(.main)
            if !others.isEmpty {
                Divider().padding(.vertical, 4)
                Text("EXISTING WORKTREES").font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim).padding(.horizontal, 10).padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(others) { option(.existing($0)) }
                    }
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .frame(width: 380)
    }

    private func option(_ c: Choice) -> some View {
        WorktreeOptionRow(icon: icon(c), title: title(c), subtitle: subtitle(c), selected: c == choice) {
            switch c {
            case .isolated: isolate = true; worktreePath = nil
            case .main: isolate = false; worktreePath = nil
            case .existing(let w): isolate = false; worktreePath = w.path
            }
            open = false
        }
    }

    private func icon(_ c: Choice) -> String {
        switch c {
        case .isolated: return "plus.square.on.square"
        case .main: return "folder"
        case .existing: return "square.stack.3d.up"
        }
    }

    private func title(_ c: Choice) -> String {
        switch c {
        case .isolated: return existing == nil ? "New worktree for PR #\(number)" : "PR #\(number) worktree"
        case .main: return "Main checkout"
        case .existing(let w): return w.name
        }
    }

    private func subtitle(_ c: Choice) -> String {
        switch c {
        case .isolated: return "\(PRWorktrees.branch(number: number)) · your checkout stays untouched"
        case .main: return folder.map(display) ?? "the local clone"
        case .existing(let w): return (w.branch ?? "detached HEAD") + " · " + display(w.path)
        }
    }

    private func detail(_ c: Choice, folder: String) -> String {
        switch c {
        case .isolated:
            return "\(existing == nil ? "Creates" : "Reuses") \(display(existing ?? PRWorktrees.path(clone: folder, number: number))) on branch \(PRWorktrees.branch(number: number)) at the pull request head. The checkout step in the prompt is replaced when it starts."
        case .main:
            return "The agent works right in \(display(folder)) and checks out the pull request branch there."
        case .existing(let w):
            return "The agent works in \(display(w.path)) (\(w.branch ?? "detached HEAD")) and checks out the pull request branch there."
        }
    }

    private func display(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func refresh() async {
        guard let folder else { existing = nil; others = []; return }
        let n = number
        existing = await Task.detached(priority: .utility) { PRWorktrees.existing(clone: folder, number: n) }.value
        let pr = existing.map(ActiveWorktree.standard)
        let main = ActiveWorktree.standard(folder)
        others = await Task.detached(priority: .utility) {
            GitWorktreeEntry.list(in: folder).filter { !$0.isMain && ActiveWorktree.standard($0.path) != main && ActiveWorktree.standard($0.path) != pr }
        }.value
        if let worktreePath, !others.contains(where: { $0.path == worktreePath }) { self.worktreePath = nil }
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

private struct WorktreeOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.syCallout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.syAgentAccent : Color.syMuted)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(selected ? Color.syAgentAccent.opacity(0.14) : Color.clear))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.syCallout.weight(selected ? .semibold : .regular)).foregroundStyle(Color.syText).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.syCaption.weight(.bold)).foregroundStyle(Color.syAgentAccent).frame(width: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && !selected ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
