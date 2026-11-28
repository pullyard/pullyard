import AppKit
import SwiftUI

/// Starts an agent session that implements a Jira ticket: pick the project folder, the Claude
/// account and the mode, edit the prompt, and the session opens under that project in Agents.
struct JiraImplementForm: View {
    let issue: JiraIssue
    let onCancel: () -> Void
    let onStarted: () -> Void

    @Environment(AppModel.self) private var app
    @State private var prompt = ""
    @State private var folder: String?
    @State private var profileID: String = ClaudeProfiles.shared.activeID
    @State private var mode: ClaudeMode = .plan
    @State private var showProjects = false
    @State private var useWorktree = false
    @State private var starting = false
    @State private var startError: String?
    @State private var showAccounts = false
    @State private var drafting = false
    @State private var draftError: String?
    /// The prompt Haiku wrote last; the user's edits after it stop auto-redrafts.
    @State private var drafted: String?
    @State private var draftRun: JiraPromptDraftRun?
    /// Haiku's open questions; while set, the form shows them instead of the prompt editor.
    @State private var questions: [JiraDraftQuestion] = []
    @State private var findings = ""
    @State private var answers: [UUID: String] = [:]
    @AppStorage("jira.implement.autoDraft") private var autoDraft = true

    private static let profileKey = "jira.implement.profile"
    private static let modeKey = "jira.implement.mode"
    private static let worktreeKey = "jira.implement.worktree"
    private static func folderKey(_ project: String) -> String { "jira.implement.folder.\(project)" }

    private var projectKey: String { JiraConnections.projectKey(of: issue.key) }

    private var projects: [ClaudeProject] {
        app.claude.projects.filter(\.exists).sorted { $0.lastActivity > $1.lastActivity }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    projectCard
                    accountCard
                }
                modePicker
                worktreeToggle
                promptEditor
            }
            .padding(24)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .task {
            if prompt.isEmpty { prompt = Self.defaultPrompt(issue) }
            if folder == nil { folder = UserDefaults.standard.string(forKey: Self.folderKey(projectKey)).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }
            if let saved = UserDefaults.standard.string(forKey: Self.profileKey), ClaudeProfiles.shared.visible.contains(where: { $0.id == saved }) {
                profileID = saved
            }
            if let saved = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(ClaudeMode.init(rawValue:)) { mode = saved }
            useWorktree = UserDefaults.standard.bool(forKey: Self.worktreeKey)
            if app.claude.projects.isEmpty { await app.claude.reloadProjects(force: false) }
        }
        .task(id: folder) {
            // The last project picked for this Jira project wins next time, even if no session was started.
            if let folder { UserDefaults.standard.set(folder, forKey: Self.folderKey(projectKey)) }
            guard autoDraft, folder != nil, untouched else { return }
            draft()
        }
        .onDisappear { draftRun?.cancel() }
    }

    /// True while the prompt is still what PullYard or Haiku wrote, so redrafting loses nothing.
    private var untouched: Bool {
        prompt.isEmpty || prompt == Self.defaultPrompt(issue) || prompt == drafted
    }

    private func draft(followUp: JiraDraftFollowUp? = nil) {
        guard let folder else { return }
        draftRun?.cancel()
        let run = JiraPromptDraftRun()
        draftRun = run
        drafting = true
        draftError = nil
        if followUp == nil { questions = []; answers = [:]; findings = "" }
        let configDir = ClaudeProfiles.shared.profile(id: profileID)?.configDir
        Task {
            do {
                let outcome = try await run.run(issue: issue, folder: folder, configDir: configDir, followUp: followUp)
                guard draftRun === run else { return }
                withAnimation(Motion.fade) {
                    switch outcome {
                    case .ready(let text):
                        questions = []
                        prompt = text
                        drafted = text
                    case .questions(let found, let asked):
                        // Keep what was already learned across rounds.
                        findings = [findings, found].filter { !$0.isEmpty }.joined(separator: "\n")
                        questions = asked
                        answers = [:]
                    }
                }
            } catch is CancellationError {
            } catch {
                if draftRun === run { draftError = error.localizedDescription }
            }
            if draftRun === run {
                drafting = false
                draftRun = nil
            }
        }
    }

    /// Sends the answers back; unanswered questions go as "skipped" so Haiku lists them instead of guessing.
    private func submitAnswers(skipAll: Bool = false) {
        let pairs = questions.map { q -> (question: String, answer: String) in
            let a = skipAll ? "" : (answers[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (q.question, a.isEmpty ? "skipped" : a)
        }
        let previous = findings
        draft(followUp: JiraDraftFollowUp(findings: previous, answers: pairs))
    }

    private func cancelDraft() {
        draftRun?.cancel()
        draftRun = nil
        drafting = false
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color.syCoral.opacity(0.35), Color.syViolet.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.syCoral)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Implement with agent").font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText)
                    HStack(spacing: 4) {
                        Image(systemName: JiraStyle.typeIcon(issue.type)).font(.syCaption2)
                        Text(issue.key).font(.syCaption.weight(.semibold).monospaced())
                    }
                    .foregroundStyle(JiraStyle.typeColor(issue.type))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(JiraStyle.typeColor(issue.type).opacity(0.14)))
                }
                Text(issue.summary)
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Project and account

    private var projectCard: some View {
        Button { showProjects.toggle() } label: {
            ImplementOptionCard(
                caption: "Project",
                title: folder.map { ($0 as NSString).lastPathComponent } ?? "Choose a project",
                subtitle: folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "The folder the agent works in",
                highlighted: folder == nil
            ) {
                IconTile(systemImage: "folder.fill", color: .syCoral, size: 30)
            }
        }
        .buttonStyle(.plain)
        .help(folder ?? "Choose the project folder")
        .popover(isPresented: $showProjects, arrowEdge: .bottom) {
            ImplementChoiceList(title: "Recent projects") {
                ForEach(projects.prefix(30)) { p in
                    ImplementChoiceRow(selected: p.path == folder, title: p.name, subtitle: (p.path as NSString).abbreviatingWithTildeInPath) {
                        IconTile(systemImage: "folder.fill", color: .syCoral, size: 24)
                    } action: {
                        folder = p.path
                        showProjects = false
                    }
                }
                if projects.isEmpty {
                    Text("No recent projects yet").font(.syCaption).foregroundStyle(Color.syMuted).padding(12)
                }
            } footer: {
                Button {
                    showProjects = false
                    chooseFolder()
                } label: {
                    Label("Choose Folder\u{2026}", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var accountCard: some View {
        let profiles = ClaudeProfiles.shared.visible
        let current = profiles.first { $0.id == profileID } ?? ClaudeProfiles.shared.active
        return Button { showAccounts.toggle() } label: {
            ImplementOptionCard(
                caption: "Claude account",
                title: current.label,
                subtitle: [current.email, current.plan].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Default account",
                highlighted: false,
                showsChevron: profiles.count > 1
            ) {
                ProfileBadge(profile: current, size: 30)
            }
        }
        .buttonStyle(.plain)
        .disabled(profiles.count < 2)
        .popover(isPresented: $showAccounts, arrowEdge: .bottom) {
            ImplementChoiceList(title: "Claude accounts") {
                ForEach(profiles) { p in
                    ImplementChoiceRow(selected: p.id == profileID, title: p.label, subtitle: [p.email, p.plan].compactMap { $0 }.joined(separator: " · ")) {
                        ProfileBadge(profile: p, size: 24)
                    } action: {
                        profileID = p.id
                        showAccounts = false
                    }
                }
            } footer: {
                EmptyView()
            }
        }
    }

    // MARK: Mode

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
            HStack(spacing: 8) {
                ForEach(ClaudeMode.allCases) { m in
                    let on = m == mode
                    Button {
                        withAnimation(Motion.fade) { mode = m }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: Self.icon(m)).font(.syCallout.weight(.semibold))
                                Text(m.title).font(.syCallout.weight(.semibold))
                            }
                            .foregroundStyle(on ? Color.syAccent : Color.syText)
                            Text(Self.blurb(m)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.syAccent.opacity(0.12) : Color.syText.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Color.syAccent.opacity(0.7) : Color.syLine, lineWidth: on ? 1.5 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private static func icon(_ mode: ClaudeMode) -> String {
        switch mode {
        case .standard: return "hand.raised.fill"
        case .acceptEdits: return "pencil.line"
        case .plan: return "list.bullet.clipboard.fill"
        case .auto: return "bolt.fill"
        }
    }

    private static func blurb(_ mode: ClaudeMode) -> String {
        switch mode {
        case .standard: return "Asks before every edit and command"
        case .acceptEdits: return "Edits files, asks before commands"
        case .plan: return "Reads and plans first, then asks"
        case .auto: return "Works on its own until done"
        }
    }

    // MARK: Worktree

    private var worktreeToggle: some View {
        Button {
            withAnimation(Motion.fade) { useWorktree.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: useWorktree ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(useWorktree ? Color.syAccent : Color.syDim)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up").font(.syCaption)
                        Text("Work in a new git worktree").font(.syCallout.weight(.semibold))
                    }
                    .foregroundStyle(Color.syText)
                    Text(useWorktree
                         ? "A separate checkout on a new claude/\(SessionWorktree.slug(issue.key + " " + issue.summary))-… branch, so your current work stays untouched."
                         : "The agent works right in \(folder.map { ($0 as NSString).lastPathComponent } ?? "the project folder"), on whatever is checked out there.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(useWorktree ? Color.syAccent.opacity(0.08) : Color.syText.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(useWorktree ? Color.syAccent.opacity(0.5) : Color.syLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(useWorktree ? .isSelected : [])
    }

    // MARK: Prompt

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Prompt").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                if drafted != nil, prompt == drafted, !drafting {
                    Label("Written by Haiku from the code", systemImage: "sparkles")
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(Color.syViolet)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.syViolet.opacity(0.12)))
                }
                Spacer()
                if drafting {
                    Button("Cancel", action: cancelDraft)
                        .buttonStyle(JiraChipButtonStyle())
                        .controlSize(.small)
                } else {
                    if prompt != Self.defaultPrompt(issue) {
                        Button { prompt = Self.defaultPrompt(issue) } label: { Label("Template", systemImage: "arrow.counterclockwise") }
                            .buttonStyle(JiraChipButtonStyle())
                            .help("Use the plain prompt built from the ticket")
                    }
                    Button { draft() } label: { Label(drafted == nil ? "Draft with Haiku" : "Redraft", systemImage: "sparkles") }
                        .buttonStyle(JiraChipButtonStyle())
                        .disabled(folder == nil)
                        .help("Haiku reads the project and the ticket, then writes a focused prompt. Cheap, read-only")
                }
                Toggle("Auto", isOn: $autoDraft)
                    .toggleStyle(.checkbox)
                    .font(.syCaption)
                    .help("Draft with Haiku as soon as a project is chosen")
                Text("\(prompt.count) characters").font(.syCaption.monospacedDigit()).foregroundStyle(Color.syDim)
            }
            if let draftError {
                Label("Haiku couldn't draft the prompt: \(draftError). The template is kept.", systemImage: "exclamationmark.triangle.fill")
                    .font(.syCaption)
                    .foregroundStyle(Color.syAmber)
                    .lineLimit(2)
            }
            if !questions.isEmpty && !drafting {
                ScrollView { questionsCard }
                    .frame(minHeight: 240, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.syViolet.opacity(0.45)))
            } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $prompt)
                    .font(.syCallout)
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .opacity(drafting ? 0 : 1)
                    .disabled(drafting)
                if drafting { draftingPlaceholder }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(drafting ? Color.syViolet.opacity(0.45) : Color.syLine))
            .frame(minHeight: 240, maxHeight: .infinity)
            }
        }
    }

    private var answeredCount: Int {
        questions.filter { !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var questionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill").font(.system(size: 18)).foregroundStyle(Color.syViolet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Haiku needs \(questions.count == 1 ? "an answer" : "\(questions.count) answers") before writing the prompt")
                        .font(.syBody.weight(.semibold)).foregroundStyle(Color.syText)
                    Text("No guesses: answer what you know. Anything you skip goes to the agent as “verify first”.")
                        .font(.syCaption).foregroundStyle(Color.syMuted)
                }
            }
            ForEach(Array(questions.enumerated()), id: \.element.id) { i, q in
                JiraQuestionCard(number: i + 1, question: q, answer: Binding(get: { answers[q.id] ?? "" }, set: { answers[q.id] = $0 }))
            }
            HStack(spacing: 10) {
                Text("\(answeredCount) of \(questions.count) answered").font(.syCaption.monospacedDigit()).foregroundStyle(Color.syMuted)
                Spacer()
                Button("Skip all") { submitAnswers(skipAll: true) }
                    .buttonStyle(JiraChipButtonStyle())
                    .help("Write the prompt now; every question goes to the agent as something to verify first")
                Button { submitAnswers() } label: { Label("Write prompt", systemImage: "sparkles") }
                    .buttonStyle(AgentGradientButtonStyle())
                    .help("Haiku writes the prompt from what it found and your answers")
            }
        }
        .padding(16)
    }

    private var draftingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                WakeLoader()
                Text("Haiku is reading \(folder.map { ($0 as NSString).lastPathComponent } ?? "the project") and \(issue.key)\u{2026}")
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syText.opacity(0.85))
            }
            ShimmerBar(width: 320, height: 12)
            ShimmerBar(height: 12)
            ShimmerBar(height: 12)
            ShimmerBar(width: 260, height: 12)
            ShimmerBar(width: 200, height: 12).padding(.top, 8)
            ShimmerBar(height: 12)
            ShimmerBar(width: 340, height: 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var canStart: Bool {
        folder != nil && !starting && !drafting && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Label("Back to ticket", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            Spacer()
            if let startError {
                Label(startError, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).lineLimit(2)
            } else if starting {
                WakeLoader()
                Text("Creating worktree\u{2026}").font(.syCaption).foregroundStyle(Color.syMuted)
            } else if folder == nil {
                Text("Choose a project to start").font(.syCaption).foregroundStyle(Color.syMuted)
            } else {
                Text("⌘↩").font(.syCaption.monospaced()).foregroundStyle(Color.syDim)
            }
            Button(action: start) {
                Label("Start session", systemImage: "play.fill")
            }
            .buttonStyle(AgentGradientButtonStyle(enabled: canStart))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
            .help(canStart ? "Start the session (⌘↩)" : "Choose a project first")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder for \(issue.key)"
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }

    private func start() {
        guard let folder, !starting else { return }
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(folder, forKey: Self.folderKey(projectKey))
        defaults.set(profileID, forKey: Self.profileKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(useWorktree, forKey: Self.worktreeKey)
        let name = "\(issue.key) \(issue.summary)"
        Task {
            var workFolder = folder
            if useWorktree {
                starting = true
                startError = nil
                let created = await SessionWorktree.create(from: folder, title: name)
                starting = false
                switch created {
                case .success(let path):
                    workFolder = path
                    text += "\n\nYou are already in a dedicated git worktree for this ticket; work and commit here."
                case .failure(let error):
                    startError = "Couldn't create a worktree: \(error.localizedDescription)"
                    return
                }
            } else {
                text += "\n\nWork directly in this checkout. Do not create a separate git worktree."
            }
            let claude = app.claude
            claude.newSession(folder: workFolder, prompt: text, name: name, mode: mode, profileID: profileID)
            // Show the account the session runs under, so it is visible in its project's section.
            if claude.accountFilter != nil { claude.accountFilter = profileID }
            onStarted()
            app.section = .claude
        }
    }

    static func defaultPrompt(_ issue: JiraIssue) -> String {
        var parts = ["Implement Jira ticket \(issue.key): \(issue.summary)", issue.url]
        if let type = issue.type { parts.append("Type: \(type)" + (issue.priority.map { " · Priority: \($0)" } ?? "")) }
        if let parent = issue.parentKey {
            parts.append("Parent: \(parent)" + (issue.parentSummary.map { " – \($0)" } ?? ""))
        }
        let description = issue.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { parts.append("Description:\n\(description)") }
        if !issue.attachments.isEmpty {
            parts.append("Attachments (in Jira): " + issue.attachments.map(\.filename).joined(separator: ", "))
        }
        parts.append("Read the relevant code first, then make a short plan and implement it. Mention \(issue.key) in the branch name and commit message.")
        return parts.joined(separator: "\n\n")
    }
}

/// A tappable summary tile for a choice in the implement form (project, account).
private struct ImplementOptionCard<Icon: View>: View {
    let caption: String
    let title: String
    let subtitle: String
    var highlighted = false
    var showsChevron = true
    @ViewBuilder let icon: Icon
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(caption.uppercased()).font(.syCaption2.weight(.semibold)).tracking(0.4).foregroundStyle(Color.syDim)
                Text(title).font(.syCallout.weight(.semibold)).foregroundStyle(highlighted ? Color.syAccent : Color.syText).lineLimit(1)
                Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.syText.opacity(hover ? 0.07 : 0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlighted ? Color.syAccent.opacity(0.7) : Color.syLine, style: StrokeStyle(lineWidth: highlighted ? 1.5 : 1, dash: highlighted ? [5, 4] : []))
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// The coral-to-violet pill used for buttons that start an agent.
struct AgentGradientButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.syCallout.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.6))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [Color.syCoral, Color.syViolet], startPoint: .leading, endPoint: .trailing))
                    .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            )
            .shadow(color: Color.syCoral.opacity(enabled ? 0.35 : 0), radius: 8, y: 2)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// A popover list of choices for the implement form.
private struct ImplementChoiceList<Rows: View, Footer: View>: View {
    let title: String
    @ViewBuilder let rows: Rows
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.syCaption2.weight(.semibold))
                .tracking(0.4)
                .foregroundStyle(Color.syDim)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { rows }
                    .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            if !(footer is EmptyView) {
                Divider()
                footer.padding(10)
            }
        }
        .frame(width: 360)
    }
}

private struct ImplementChoiceRow<Icon: View>: View {
    let selected: Bool
    let title: String
    var subtitle = ""
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.syCallout.weight(.medium)).foregroundStyle(Color.syText).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.syAccent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.syAccent.opacity(0.12) : Color.syText.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One of Haiku's questions: pick an option or type an answer. "Ask backend" questions can be copied to forward.
private struct JiraQuestionCard: View {
    let number: Int
    let question: JiraDraftQuestion
    @Binding var answer: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.syCaption.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.syViolet)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.syViolet.opacity(0.15)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.question).font(.syBody.weight(.medium)).foregroundStyle(Color.syText).fixedSize(horizontal: false, vertical: true)
                    if let why = question.why, !why.isEmpty {
                        Text(why).font(.syCaption).foregroundStyle(Color.syMuted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let ask = question.askLabel {
                    Button {
                        copyToPasteboard(question.question)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : ask, systemImage: copied ? "checkmark" : "person.2.wave.2")
                            .font(.syCaption2.weight(.semibold))
                            .foregroundStyle(Color.syAmber)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.syAmber.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the question to send it on")
                }
            }
            if !question.options.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        let on = answer == option
                        Button { answer = on ? "" : option } label: {
                            HStack(spacing: 5) {
                                if on { Image(systemName: "checkmark").font(.syCaption2.weight(.bold)) }
                                Text(option).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .font(.syCallout)
                            .foregroundStyle(on ? Color.white : Color.syText.opacity(0.88))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Color.syViolet.opacity(0.85) : Color.syText.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(on ? Color.clear : Color.syLine))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 28)
            }
            TextField(question.options.isEmpty ? "Your answer" : "Or type your own answer", text: $answer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.syCallout)
                .lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.syLine))
                .padding(.leading, 28)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.syText.opacity(0.03)))
    }
}
