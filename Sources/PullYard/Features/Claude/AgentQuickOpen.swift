import SwiftUI

struct AgentQuickOpen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    enum Entry: Identifiable {
        case tab(ClaudeTab)
        case session(ClaudeSessionInfo, project: String)
        case newSession(ClaudeProject)

        var id: String {
            switch self {
            case .tab(let t): return "t" + t.id.uuidString
            case .session(let s, _): return "s" + s.id
            case .newSession(let p): return "n" + p.id
            }
        }
    }

    private var ws: ClaudeWorkspace { app.claude }

    private var entries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func hit(_ parts: String?...) -> Bool {
            q.isEmpty || parts.contains { $0?.lowercased().contains(q) == true }
        }
        let openIDs = Set(ws.tabs.map(\.sessionId))
        let tabs = ws.tabs.filter { hit($0.title, $0.projectName) }.map(Entry.tab)
        let sessions = ws.projects
            .flatMap { p in p.sessions.filter { !$0.archived && !openIDs.contains($0.id) }.map { ($0, p.name) } }
            .filter { hit($0.0.title, $0.1, $0.0.branch) }
            .sorted { $0.0.modified > $1.0.modified }
            .prefix(q.isEmpty ? 12 : 40)
            .map { Entry.session($0.0, project: $0.1) }
        let projects = ws.projects.filter { $0.exists && hit($0.name, "new") }.prefix(q.isEmpty ? 4 : 8).map(Entry.newSession)
        return tabs + sessions + projects
    }

    var body: some View {
        let list = entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.syMuted)
                TextField("Go to a session or start one in a project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { open(list) }
                    .onKeyPress(.downArrow) { move(1, list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, list.count); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Rectangle().fill(Color.syLine).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = index
                                    open(list)
                                }
                        }
                        if list.isEmpty {
                            Text("Nothing matches “\(query)”").foregroundStyle(Color.syMuted).padding(16)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, i in withAnimation(Motion.quick) { proxy.scrollTo(i, anchor: .center) } }
            }
            .frame(height: 340)
            Rectangle().fill(Color.syLine).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", "select")
                hint("↩", "open")
                hint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 560)
        .background(Color.syPanel)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.syCaption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.syText.opacity(0.08)))
            Text(text).font(.syCaption)
        }
        .foregroundStyle(Color.syMuted)
    }

    @ViewBuilder
    private func row(_ entry: Entry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch entry {
            case .tab(let t):
                SessionIndicatorDot(indicator: SessionIndicator(tab: t))
                Text(t.title).foregroundStyle(Color.syText).lineLimit(1)
                Spacer(minLength: 8)
                Text("open · " + t.projectName).font(.syCaption).foregroundStyle(Color.syDim)
            case .session(let s, let project):
                SessionIndicatorDot(indicator: ws.indicator(for: s))
                Text(s.title).foregroundStyle(Color.syText).lineLimit(1)
                Spacer(minLength: 8)
                Text(project + " · " + Fmt.rel(s.modified)).font(.syCaption).foregroundStyle(Color.syDim)
            case .newSession(let p):
                Image(systemName: "plus").foregroundStyle(Color.syAgentAccent).frame(width: 14)
                Text("New session in ") .foregroundStyle(Color.syMuted) + Text(p.name).foregroundStyle(Color.syText)
                Spacer(minLength: 8)
            }
        }
        .font(.syBody)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.syAgentAccent.opacity(0.16) : .clear))
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func open(_ list: [Entry]) {
        guard list.indices.contains(selection) else { return }
        app.section = .claude
        switch list[selection] {
        case .tab(let t): ws.selectedTabID = t.id
        case .session(let s, _): ws.resume(s)
        case .newSession(let p): ws.newSession(folder: p.path)
        }
        dismiss()
    }
}
