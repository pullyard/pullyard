import SwiftUI

/// The ticket's fields as chips that edit in place: assignee, reporter, priority, sprint.
struct JiraIssueFields: View {
    let issue: JiraIssue
    let onChange: (JiraIssue) -> Void
    @State private var info: JiraEditInfo?
    @State private var saving: Field?
    @State private var error: String?
    @State private var open: Field?

    enum Field: String, Identifiable { case assignee, reporter, priority, sprint; var id: String { rawValue } }

    private var client: JiraClient? { JiraConnections.shared.client(for: issue.connectionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                chip(.assignee, label: "Assignee") {
                    if let a = issue.assignee {
                        Avatar(url: issue.assigneeAvatar, size: 16)
                        Text(a)
                    } else {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                        Text("Unassigned")
                    }
                }
                chip(.reporter, label: "Reporter") {
                    if let r = info?.reporter {
                        Avatar(url: r.avatar, size: 16)
                        Text(r.displayName)
                    } else {
                        Image(systemName: "megaphone")
                        Text(issue.reporter ?? "Reporter")
                    }
                }
                chip(.priority, label: "Priority") {
                    Image(systemName: "flag.fill").foregroundStyle(JiraStyle.priorityColor(issue.priority))
                    Text(issue.priority ?? "No priority")
                }
                if info == nil || info?.boardID != nil || info?.sprint != nil || sprintBoard != nil {
                    chip(.sprint, label: "Sprint") {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(info?.sprint?.name ?? (info == nil ? "Sprint" : "Backlog"))
                    }
                }
                if let u = issue.updated {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                        Text(Fmt.rel(u))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Color.syText.opacity(0.05)))
                    .help("Updated")
                }
            }
            .font(.syCaption)
            .foregroundStyle(Color.syMuted)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).lineLimit(2)
            }
        }
        .task(id: issue.key) { await loadInfo() }
    }

    /// The board to pick sprints from: the issue's own, else the board that is open for this connection.
    private var sprintBoard: Int? {
        if let id = info?.boardID { return id }
        let model = JiraBoardModel.shared
        guard model.connectionID == issue.connectionID, let b = model.snap.board, b.isScrum else { return nil }
        return b.id
    }

    private func editable(_ f: Field) -> Bool {
        guard let info else { return false }
        switch f {
        case .assignee: return info.can("assignee")
        case .reporter: return info.can("reporter")
        case .priority: return info.can("priority") && !info.priorities.isEmpty
        case .sprint: return sprintBoard != nil
        }
    }

    private func chip<C: View>(_ f: Field, label: String, @ViewBuilder _ content: () -> C) -> some View {
        let can = editable(f)
        return Button { open = f } label: {
            HStack(spacing: 5) {
                if saving == f { WakeLoader() } else { content() }
                if can { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.syDim) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Color.syText.opacity(open == f ? 0.12 : 0.05)))
            .overlay(Capsule().strokeBorder(Color.syText.opacity(open == f ? 0.2 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(JiraHoverChipStyle())
        .disabled(!can || saving != nil)
        .help(can ? "Change \(label.lowercased())" : label)
        .popover(isPresented: Binding(get: { open == f }, set: { if !$0, open == f { open = nil } }), arrowEdge: .bottom) {
            panel(f)
        }
    }

    @ViewBuilder
    private func panel(_ f: Field) -> some View {
        switch f {
        case .assignee:
            JiraPeoplePicker(issueKey: issue.key, client: client, title: "ASSIGNEE", current: info?.assignee, allowsNone: true) { user in
                open = nil
                save(.assignee) { try await $0.assign(issue.key, to: user) }
            }
        case .reporter:
            JiraPeoplePicker(issueKey: issue.key, client: client, title: "REPORTER", current: info?.reporter, allowsNone: false) { user in
                open = nil
                guard let user else { return }
                save(.reporter) { try await $0.update(issue.key, fields: ["reporter": user.ref]) }
            }
        case .priority:
            VStack(alignment: .leading, spacing: 2) {
                JiraPanelTitle("PRIORITY")
                ForEach(info?.priorities ?? []) { p in
                    JiraPickRow(selected: p.id == info?.priorityID, title: p.name) {
                        Image(systemName: "flag.fill").foregroundStyle(JiraStyle.priorityColor(p.name))
                    } action: {
                        open = nil
                        save(.priority) { try await $0.update(issue.key, fields: ["priority": ["id": p.id]]) }
                    }
                }
            }
            .padding(6)
            .frame(width: 240)
        case .sprint:
            JiraSprintPicker(board: sprintBoard, client: client, current: info?.sprint) { sprint in
                open = nil
                save(.sprint) { try await $0.move(issue.key, toSprint: sprint?.id) }
            }
        }
    }

    private func loadInfo() async {
        guard let client else { return }
        do { info = try await client.editInfo(issue.key) } catch { self.error = error.localizedDescription }
    }

    private func save(_ f: Field, _ work: @escaping (JiraClient) async throws -> Void) {
        guard let client else { return }
        saving = f
        error = nil
        let id = issue.connectionID
        Task {
            do {
                try await work(client)
                var updated = try await client.issue(issue.key)
                updated.connectionID = id
                JiraConnections.shared.remember(updated)
                info = try? await client.editInfo(issue.key)
                onChange(updated)
                if f == .sprint { Task { await JiraBoardModel.shared.loadBoard() } }
            } catch {
                self.error = error.localizedDescription
            }
            saving = nil
        }
    }
}

struct JiraHoverChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(hover && enabled ? Color.syText : Color.syMuted)
                .brightness(hover && enabled ? 0.06 : 0)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hover = $0 }
        }
    }
}

struct JiraPanelTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }
}

struct JiraPickRow<Icon: View>: View {
    let selected: Bool
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.syCallout.weight(selected ? .semibold : .regular)).foregroundStyle(Color.syText).lineLimit(1)
                    if let subtitle { Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.syCaption.weight(.bold)).foregroundStyle(Color.syAgentAccent).frame(width: 14)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover && !selected ? Color.syText.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!selected)
        .onHover { hover = $0 }
    }
}

struct JiraPeoplePicker: View {
    let issueKey: String
    let client: JiraClient?
    let title: String
    let current: JiraUser?
    let allowsNone: Bool
    let onPick: (JiraUser?) -> Void
    @State private var query = ""
    @State private var people: [JiraUser] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            JiraPanelTitle(title)
            TextField("Search people", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if allowsNone, query.isEmpty {
                        JiraPickRow(selected: current == nil, title: "Unassigned") {
                            Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Color.syMuted)
                        } action: { onPick(nil) }
                    }
                    if loading && people.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ShimmerBar(width: 180, height: 12)
                            ShimmerBar(width: 140, height: 12)
                            ShimmerBar(width: 200, height: 12)
                        }
                        .padding(10)
                    }
                    ForEach(people) { p in
                        JiraPickRow(selected: p.id == current?.id, title: p.displayName, subtitle: p.email) {
                            Avatar(url: p.avatar, size: 22)
                        } action: { onPick(p) }
                    }
                    if !loading && people.isEmpty {
                        Text("Nobody matches").font(.syCaption).foregroundStyle(Color.syMuted).padding(10)
                    }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(width: 300)
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, let client else { return }
            loading = true
            let found = (try? await client.users(for: issueKey, query: query)) ?? []
            guard !Task.isCancelled else { return }
            // The current person first, so it is easy to see who it is now.
            if let current, query.isEmpty, !found.contains(where: { $0.id == current.id }) {
                people = [current] + found
            } else {
                people = found.sorted { a, _ in a.id == current?.id }
            }
            loading = false
        }
    }
}

struct JiraSprintPicker: View {
    let board: Int?
    let client: JiraClient?
    let current: JiraSprint?
    let onPick: (JiraSprint?) -> Void
    @State private var sprints: [JiraSprint] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            JiraPanelTitle("SPRINT")
            if loading {
                VStack(alignment: .leading, spacing: 10) {
                    ShimmerBar(width: 160, height: 12)
                    ShimmerBar(width: 200, height: 12)
                }
                .padding(10)
            }
            ForEach(sprints) { s in
                JiraPickRow(selected: s.id == current?.id, title: s.name, subtitle: s.endDate.map { "ends " + Fmt.rel($0) }) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(s.id == current?.id ? Color.syAgentAccent : Color.syMuted)
                } action: { onPick(s) }
            }
            Divider().padding(.vertical, 4)
            JiraPickRow(selected: current == nil && !loading, title: "Backlog", subtitle: "out of any sprint") {
                Image(systemName: "tray").foregroundStyle(Color.syMuted)
            } action: { onPick(nil) }
        }
        .padding(6)
        .frame(width: 280)
        .task {
            guard let board, let client else { loading = false; return }
            sprints = (try? await client.sprints(board: board)) ?? []
            loading = false
        }
    }
}

/// Edits the description as Jira stores it (wiki markup), so formatting survives.
struct JiraDescriptionEditor: View {
    let issue: JiraIssue
    let onDone: () -> Void
    let onChange: (JiraIssue) -> Void
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DESCRIPTION").font(.syCaption2.weight(.semibold)).tracking(0.6).foregroundStyle(Color.syDim)
                Text("Jira formatting: *bold*, # numbered, * bullet, h3. heading").font(.syCaption2).foregroundStyle(Color.syDim)
                Spacer()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.syBody)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .opacity(loading ? 0 : 1)
                if loading {
                    VStack(alignment: .leading, spacing: 10) {
                        ShimmerBar(width: 200, height: 12)
                        ShimmerBar(height: 12)
                        ShimmerBar(width: 260, height: 12)
                    }
                    .padding(14)
                }
            }
            .frame(minHeight: 220)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.syAgentAccent.opacity(0.45)))
            HStack(spacing: 8) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed).lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(JiraChipButtonStyle())
                Button { save() } label: {
                    HStack(spacing: 6) {
                        if saving { WakeLoader() }
                        Text(saving ? "Saving…" : "Save")
                    }
                }
                .buttonStyle(AgentGradientButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(loading || saving || text == original)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.sySunken))
        .task {
            guard let client = JiraConnections.shared.client(for: issue.connectionID) else { return }
            do {
                let raw = try await client.editInfo(issue.key).rawDescription
                text = raw
                original = raw
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func save() {
        guard let client = JiraConnections.shared.client(for: issue.connectionID) else { return }
        saving = true
        error = nil
        let id = issue.connectionID
        Task {
            do {
                try await client.update(issue.key, fields: ["description": text])
                var updated = try await client.issue(issue.key)
                updated.connectionID = id
                JiraConnections.shared.remember(updated)
                onChange(updated)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
