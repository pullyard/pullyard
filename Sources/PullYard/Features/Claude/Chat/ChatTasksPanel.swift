import AppKit
import SwiftUI

enum ChatTaskState {
    case running, done, failed, stopped

    init(_ call: ChatToolCall) {
        if call.backgrounded || call.taskStatus != nil {
            switch call.taskStatus {
            case nil, "running", "pending": self = call.backgrounded || call.status == .running ? .running : Self(status: call.status)
            case "completed": self = .done
            case "failed": self = .failed
            default: self = .stopped
            }
        } else {
            self = Self(status: call.status)
        }
    }

    private init(status: ChatToolCall.Status) {
        switch status {
        case .running: self = .running
        case .done: self = .done
        case .error: self = .failed
        case .denied: self = .stopped
        }
    }
}

extension ChatSession {
    static let taskTools: Set<String> = ["Bash", "Agent", "Task"]

    var taskCalls: [ChatToolCall] {
        items.compactMap { item in
            guard case .tool(let call) = item, Self.taskTools.contains(call.name) else { return nil }
            return call
        }
    }
}

struct ChatTasksPanel: View {
    let chat: ChatSession
    @State private var showFinished = true
    @State private var expanded: Set<String> = []

    var body: some View {
        let calls = chat.taskCalls.reversed()
        let running = calls.filter { ChatTaskState($0) == .running }
        let finished = calls.filter { ChatTaskState($0) != .running }
        Group {
            if calls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.syLargeTitle).foregroundStyle(Color.syDim)
                    Text("Commands and agents Claude runs will show up here")
                        .font(.syCallout).foregroundStyle(Color.syMuted).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !running.isEmpty {
                            sectionHeader("Running \(running.count)", collapsible: false)
                            ForEach(running) { row($0) }
                        }
                        if !finished.isEmpty {
                            sectionHeader("Finished \(finished.count)", collapsible: true)
                            if showFinished {
                                ForEach(finished) { row($0) }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, collapsible: Bool) -> some View {
        Button {
            guard collapsible else { return }
            withAnimation(Motion.fade) { showFinished.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                if collapsible {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.syDim)
                        .rotationEffect(.degrees(showFinished ? 0 : -90))
                }
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ call: ChatToolCall) -> some View {
        ChatTaskRow(call: call, open: expanded.contains(call.id)) {
            withAnimation(Motion.fade) {
                if expanded.contains(call.id) { expanded.remove(call.id) } else { expanded.insert(call.id) }
            }
        }
    }
}

private struct ChatTaskRow: View {
    let call: ChatToolCall
    let open: Bool
    let toggle: () -> Void
    @State private var hover = false

    private var state: ChatTaskState { ChatTaskState(call) }
    private var isAgent: Bool { call.name != "Bash" }
    private var command: String { call.string("command") ?? "" }

    private var title: String {
        if let d = call.string("description"), !d.isEmpty { return d }
        if let first = command.split(separator: "\n").first { return String(first) }
        return call.string("prompt").map { String($0.prefix(80)) } ?? call.name
    }

    private var subtitle: String? {
        guard isAgent else { return call.backgrounded ? "Background" : nil }
        var parts: [String] = []
        if let type = call.string("subagent_type") { parts.append(type) }
        if let tokens = call.taskTokens { parts.append(Self.tokens(tokens) + " tokens") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var output: String? {
        if let s = call.structured {
            let out = [s["stdout"] as? String, s["stderr"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            if !out.isEmpty { return out }
        }
        if let summary = call.taskSummary { return summary }
        if isAgent, let text = call.agentText { return text }
        return call.resultText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isAgent ? "person.2" : "terminal")
                        .font(.syCaption)
                        .foregroundStyle(Color.syDim)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.syCallout)
                            .foregroundStyle(Color.syText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let subtitle {
                            Text(subtitle).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    trailing
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.syDim)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { details }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.syText.opacity(hover || open ? 0.05 : 0)))
        .onHover { hover = $0 }
        .contextMenu {
            if !command.isEmpty {
                Button("Copy Command") { copy(command) }
            }
            if let output {
                Button("Copy Output") { copy(output) }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .running:
            HStack(spacing: 6) {
                if let start = call.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.duration(context.date.timeIntervalSince(start)))
                            .font(.syCaption.monospacedDigit())
                            .foregroundStyle(Color.syMuted)
                    }
                }
                ProgressView().controlSize(.mini)
            }
        case .failed:
            Text("Failed").font(.syCaption.weight(.medium)).foregroundStyle(Color.syRed)
        case .stopped:
            Text("Stopped").font(.syCaption).foregroundStyle(Color.syMuted)
        case .done:
            if let start = call.startedAt, let end = call.finishedAt {
                Text(Self.duration(end.timeIntervalSince(start)))
                    .font(.syCaption.monospacedDigit())
                    .foregroundStyle(Color.syMuted)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !command.isEmpty {
                Text("$ " + command)
                    .font(.syCaption.monospaced())
                    .foregroundStyle(Color.syText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.sySunken))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.syLine))
            }
            if let output, !output.isEmpty {
                ScrollView {
                    Text(String(output.suffix(8_000)))
                        .font(.syCaption.monospaced())
                        .foregroundStyle(state == .failed ? Color.syRed : Color.syMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.syText.opacity(0.06)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }
}
