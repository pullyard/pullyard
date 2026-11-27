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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconTile(systemImage: "sparkles", color: .syCoral, size: 24)
                Text("Implement \(issue.key) with an agent").font(.syTitle3.weight(.semibold)).foregroundStyle(Color.syText)
                Spacer()
            }
            Text(issue.summary).font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(2)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Project").foregroundStyle(Color.syMuted).gridColumnAlignment(.trailing)
                    projectPicker
                }
                GridRow {
                    Text("Claude account").foregroundStyle(Color.syMuted)
                    accountPicker
                }
                GridRow {
                    Text("Mode").foregroundStyle(Color.syMuted)
                    Picker("", selection: $mode) {
                        ForEach(ClaudeMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                }
            }
            .font(.syCallout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt").font(.syCallout).foregroundStyle(Color.syMuted)
                TextEditor(text: $prompt)
                    .font(.syBody)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.syText.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
                    .frame(minHeight: 260, maxHeight: .infinity)
            }

            HStack {
                Button("Back", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    start()
                } label: {
                    Label("Start session", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(folder == nil ? "Choose a project first" : "Start the session (⌘↩)")
            }
        }
        .padding(24)
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

    private var projectPicker: some View {
        Menu {
            ForEach(projects.prefix(30)) { p in
                Button {
                    folder = p.path
                } label: {
                    if p.path == folder { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
                .help(p.path)
            }
            if !projects.isEmpty { Divider() }
            Button("Choose Folder\u{2026}") { chooseFolder() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Color.syCoral)
                Text(folder.map { ($0 as NSString).lastPathComponent } ?? "Choose a project").lineLimit(1)
            }
        }
        .fixedSize()
        .help(folder ?? "The folder the agent works in")
    }

    private var accountPicker: some View {
        Picker("", selection: $profileID) {
            ForEach(ClaudeProfiles.shared.visible) { p in
                Text(p.email.map { "\(p.label) · \($0)" } ?? p.label).tag(p.id)
            }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(ClaudeProfiles.shared.visible.count < 2)
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
