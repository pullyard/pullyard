import SwiftUI

enum ToolStep: Identifiable {
    case call(ChatToolCall)
    case thinking(ChatText)

    var id: String {
        switch self {
        case .call(let c): return c.id
        case .thinking(let t): return "k" + t.id
        }
    }

    var call: ChatToolCall? {
        if case .call(let c) = self { return c }
        return nil
    }
}

enum ChatDisplayItem: Identifiable {
    case item(ChatItem)
    case tools(id: String, steps: [ToolStep])

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .tools(let id, _): return "g" + id
        }
    }

    static func build(_ items: [ChatItem]) -> [ChatDisplayItem] {
        var out: [ChatDisplayItem] = []
        var run: [ToolStep] = []
        func flush() {
            guard let first = run.first(where: { $0.call != nil })?.call else {
                for step in run { if case .thinking(let t) = step { out.append(.item(.thinking(t))) } }
                run = []
                return
            }
            out.append(.tools(id: first.id, steps: run))
            run = []
        }
        for item in items {
            switch item {
            case .tool(let call) where ToolGrouping.groupable(call):
                run.append(.call(call))
            case .thinking(let t) where !run.isEmpty:
                run.append(.thinking(t))
            default:
                flush()
                out.append(.item(item))
            }
        }
        flush()
        return out
    }
}

enum ToolGrouping {
    static func groupable(_ call: ChatToolCall) -> Bool {
        if let p = call.permission, !p.resolved { return false }
        switch call.name {
        case "TodoWrite", "ExitPlanMode", "AskUserQuestion": return false
        default: return true
        }
    }

    private enum Kind: Int, CaseIterable {
        case command, read, edit, search, web, agent, other

        var verb: String {
            switch self {
            case .command: return "Ran"
            case .read: return "Read"
            case .edit: return "Edited"
            case .search: return "Searched"
            case .web: return "Fetched"
            case .agent: return "Ran"
            case .other: return "Used"
            }
        }

        func noun(_ n: Int) -> String {
            switch self {
            case .command: return plural(n, "command", "commands")
            case .read, .edit: return plural(n, "file", "files")
            case .search: return plural(n, "pattern", "patterns")
            case .web: return plural(n, "page", "pages")
            case .agent: return plural(n, "agent", "agents")
            case .other: return plural(n, "tool", "tools")
            }
        }
    }

    private static func kind(_ name: String) -> Kind {
        switch name {
        case "Bash", "BashOutput", "KillShell": return .command
        case "Read": return .read
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .edit
        case "Grep", "Glob": return .search
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .agent
        default: return .other
        }
    }

    static func tint(_ name: String) -> Color {
        switch kind(name) {
        case .command: return .sySky
        case .read: return .syViolet
        case .edit: return .syAgentAccent
        case .search: return .syTeal
        case .web: return .syIndigo
        case .agent: return .syAmber
        case .other: return .syMuted
        }
    }

    static func label(_ calls: [ChatToolCall]) -> String {
        var counts: [Kind: Int] = [:]
        for c in calls { counts[kind(c.name), default: 0] += 1 }
        let parts = Kind.allCases.compactMap { k -> String? in
            guard let n = counts[k] else { return nil }
            return "\(k.verb.lowercased()) \(k.noun(n))"
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func commandHint(_ call: ChatToolCall) -> String? {
        guard call.name == "Bash", let d = call.input["description"] as? String, !d.isEmpty,
              let line = (call.input["command"] as? String)?.split(separator: "\n").first else { return nil }
        return String(line)
    }

    static func title(_ call: ChatToolCall, folder: String) -> String {
        let i = call.input
        let path = { (key: String) in ToolPresentation.relative(i[key] as? String ?? "", folder) }
        switch call.name {
        case "Bash":
            if let d = i["description"] as? String, !d.isEmpty { return d }
            return (i["command"] as? String)?.split(separator: "\n").first.map(String.init) ?? "Command"
        case "Read": return "Read " + path("file_path")
        case "Edit", "MultiEdit": return "Edited " + path("file_path")
        case "Write": return "Wrote " + path("file_path")
        case "NotebookEdit": return "Edited " + path("notebook_path")
        case "Grep": return "Searched for \"\(i["pattern"] as? String ?? "")\""
        case "Glob": return "Found files matching \(i["pattern"] as? String ?? "")"
        case "WebFetch": return "Fetched " + ((i["url"] as? String).flatMap { URL(string: $0)?.host } ?? "page")
        case "WebSearch": return "Searched the web for \"\(i["query"] as? String ?? "")\""
        case "Task", "Agent":
            let steps = call.children.isEmpty ? "" : " · " + plural(call.children.count, "step", "steps")
            return "Agent: " + (i["description"] as? String ?? "task") + steps
        default:
            let summary = ToolPresentation.summary(call, folder: folder)
            return summary.isEmpty ? ToolPresentation.title(call) : ToolPresentation.title(call) + " " + summary
        }
    }
}

struct ToolGroupView: View {
    let id: String
    let steps: [ToolStep]
    let chat: ChatSession
    let folder: String

    private var calls: [ChatToolCall] { steps.compactMap(\.call) }
    private var groupKey: String { "g" + id }

    private var open: Bool {
        chat.expandedTools.contains(groupKey) || calls.contains { chat.expandedTools.contains($0.id) }
    }

    var body: some View {
        if steps.count == 1, let call = steps.first?.call {
            ToolRowView(call: call, chat: chat, folder: folder, framed: false)
        } else {
            let calls = self.calls
            VStack(alignment: .leading, spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 6) {
                        if calls.contains(where: { $0.status == .running }) {
                            WakeLoader()
                        }
                        ToolKindDots(calls: calls)
                        if let running = calls.last(where: { $0.status == .running }) {
                            Text("Running: " + ToolGrouping.title(running, folder: folder)).foregroundStyle(Color.syText).lineLimit(1).truncationMode(.middle)
                        } else {
                            Text(ToolGrouping.label(calls)).foregroundStyle(Color.syMuted)
                        }
                        let failed = calls.filter { $0.status == .error }.count
                        if failed > 0 {
                            Text("· \(failed) failed").foregroundStyle(Color.syRed)
                        }
                        Image(systemName: "chevron.right")
                            .font(.syCaption2.weight(.semibold))
                            .foregroundStyle(Color.syDim)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .font(.syCallout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            if index > 0 { Rectangle().fill(Color.syLine).frame(height: 1) }
                            switch step {
                            case .call(let call): ToolRowView(call: call, chat: chat, folder: folder, framed: true)
                            case .thinking(let t): ThinkingStepRow(text: t, chat: chat)
                            }
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
                    .transition(.reveal)
                }
            }
        }
    }

    private func toggle() {
        withAnimation(Motion.quick) {
            if open {
                chat.expandedTools.remove(groupKey)
                for c in calls { chat.expandedTools.remove(c.id) }
            } else {
                chat.expandedTools.insert(groupKey)
            }
        }
    }
}

struct ThinkingStepRow: View {
    let text: ChatText
    let chat: ChatSession

    private var key: String { "k" + text.id }
    private var open: Bool { chat.expandedTools.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.quick) {
                    if open { chat.expandedTools.remove(key) } else { chat.expandedTools.insert(key) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking").foregroundStyle(Color.syDim)
                    Image(systemName: "chevron.right")
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(Color.syDim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .font(.syCallout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                Text(text.text).font(.syCallout).foregroundStyle(Color.syMuted).textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.reveal)
            }
        }
    }
}

struct ToolRowView: View {
    let call: ChatToolCall
    let chat: ChatSession
    let folder: String
    let framed: Bool

    private var open: Bool { chat.expandedTools.contains(call.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(Motion.quick) {
                        if open { chat.expandedTools.remove(call.id) } else { chat.expandedTools.insert(call.id) }
                    }
                } label: {
                    HStack(spacing: 7) {
                        statusGlyph
                        Image(systemName: ToolPresentation.icon(call.name))
                            .font(.syCaption)
                            .foregroundStyle(ToolGrouping.tint(call.name))
                            .frame(width: 14)
                        Text(ToolGrouping.title(call, folder: folder))
                            .foregroundStyle(Color.syText.opacity(call.status == .running ? 1 : 0.86))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let command = ToolGrouping.commandHint(call) {
                            Text(command)
                                .font(.sy(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.syMuted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        if let stat = ToolPresentation.diffStat(call) { stat }
                        if taskState == .stopped {
                            Text("Stopped").font(.syCaption).foregroundStyle(Color.syMuted)
                        } else if taskState == .stopping {
                            Text("Stopping…").font(.syCaption).foregroundStyle(Color.syMuted)
                        }
                        Image(systemName: "chevron.right")
                            .font(.syCaption2.weight(.semibold))
                            .foregroundStyle(Color.syDim)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .font(.syCallout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                if ToolStopButton.shows(call) {
                    ToolStopButton(call: call, chat: chat)
                }
            }
            .padding(.horizontal, framed ? 10 : 0)
            .padding(.vertical, framed ? 7 : 0)
            if open {
                details
                    .padding(.horizontal, framed ? 10 : 0)
                    .padding(.top, framed ? 0 : 6)
                    .padding(.bottom, framed ? 10 : 0)
                    .transition(.reveal)
            }
        }
    }

    private var taskState: ChatTaskState? {
        ChatSession.taskTools.contains(call.name) ? ChatTaskState(call) : nil
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if taskState?.isActive == true, call.status != .running {
            WakeLoader()
        } else {
            plainStatusGlyph
        }
    }

    @ViewBuilder
    private var plainStatusGlyph: some View {
        switch call.status {
        case .running: WakeLoader()
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syRed).accessibilityLabel("Failed")
        case .denied: Image(systemName: "nosign").foregroundStyle(Color.syAmber).accessibilityLabel("Denied")
        case .done: EmptyView()
        }
    }

    @ViewBuilder
    private var details: some View {
        if call.name == "Task" || call.name == "Agent" {
            VStack(alignment: .leading, spacing: 8) {
                if !call.children.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(call.children.enumerated()), id: \.element.id) { index, child in
                            if index > 0 { Rectangle().fill(Color.syLine).frame(height: 1) }
                            ToolRowView(call: child, chat: chat, folder: folder, framed: true)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.syLine))
                }
                if let text = call.resultText ?? call.agentText, !text.isEmpty {
                    MarkdownView(text: text, muted: true, baseStyle: .callout)
                }
            }
        } else {
            ToolDetails(call: call, folder: folder)
        }
    }
}

struct ToolKindDots: View {
    let calls: [ChatToolCall]

    var body: some View {
        var seen: [String] = []
        for c in calls {
            let icon = ToolPresentation.icon(c.name)
            if !seen.contains(icon) { seen.append(icon) }
        }
        let names = Dictionary(calls.map { (ToolPresentation.icon($0.name), $0.name) }, uniquingKeysWith: { a, _ in a })
        return HStack(spacing: 4) {
            ForEach(seen.prefix(4), id: \.self) { icon in
                Image(systemName: icon)
                    .font(.syCaption2)
                    .foregroundStyle(ToolGrouping.tint(names[icon] ?? ""))
            }
        }
    }
}
