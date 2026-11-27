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

    private static let profileKey = "jira.implement.profile"
    private static let modeKey = "jira.implement.mode"
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
            if app.claude.projects.isEmpty { await app.claude.reloadProjects(force: false) }
        }
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
        Menu {
            if !projects.isEmpty {
                Section("Recent projects") {
                    ForEach(projects.prefix(30)) { p in
                        Button {
                            folder = p.path
                        } label: {
                            if p.path == folder { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                }
            }
            Divider()
            Button("Choose Folder\u{2026}") { chooseFolder() }
        } label: {
            ImplementOptionCard(
                caption: "Project",
                title: folder.map { ($0 as NSString).lastPathComponent } ?? "Choose a project",
                subtitle: folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "The folder the agent works in",
                highlighted: folder == nil
            ) {
                IconTile(systemImage: "folder.fill", color: .syCoral, size: 30)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(folder ?? "Choose the project folder")
    }

    private var accountCard: some View {
        let profiles = ClaudeProfiles.shared.visible
        let current = profiles.first { $0.id == profileID } ?? ClaudeProfiles.shared.active
        return Menu {
            ForEach(profiles) { p in
                Button {
                    profileID = p.id
                } label: {
                    let title = p.email.map { "\(p.label) · \($0)" } ?? p.label
                    if p.id == profileID { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            ImplementOptionCard(
                caption: "Claude account",
                title: current.label,
                subtitle: current.email ?? current.plan ?? "Default account",
                highlighted: false,
                showsChevron: profiles.count > 1
            ) {
                ProfileBadge(profile: current, size: 30)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(profiles.count < 2)
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

    // MARK: Prompt

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                Spacer()
                if prompt != Self.defaultPrompt(issue) {
                    Button {
                        prompt = Self.defaultPrompt(issue)
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise").font(.syCaption)
                    }
                    .buttonStyle(.borderless)
                    .help("Rebuild the prompt from the ticket")
                }
                Text("\(prompt.count) characters").font(.syCaption.monospacedDigit()).foregroundStyle(Color.syDim)
            }
            TextEditor(text: $prompt)
                .font(.syCallout)
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.syLine))
                .frame(minHeight: 240, maxHeight: .infinity)
        }
    }

    // MARK: Footer

    private var canStart: Bool {
        folder != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Label("Back to ticket", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            Spacer()
            if folder == nil {
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
        guard let folder else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = UserDefaults.standard
        defaults.set(folder, forKey: Self.folderKey(projectKey))
        defaults.set(profileID, forKey: Self.profileKey)
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        let claude = app.claude
        claude.newSession(folder: folder, prompt: text, name: "\(issue.key) \(issue.summary)", mode: mode, profileID: profileID)
        // Show the account the session runs under, so it is visible in its project's section.
        if claude.accountFilter != nil { claude.accountFilter = profileID }
        onStarted()
        app.section = .claude
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
