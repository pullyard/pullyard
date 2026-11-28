import ActivityKit
import Foundation

@MainActor
enum AgentActivities {
    typealias State = AgentActivityAttributes.ContentState

    private static var tracked: Set<String> = []
    private static var pending: [String: State] = [:]
    private static var inFlight: Set<String> = []

    static let enabledKey = "agents.liveActivity"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func endAll() {
        pending = [:]
        let activities = Activity<AgentActivityAttributes>.activities
        Task { for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) } }
    }

    static func dismissFinished() {
        let done = Activity<AgentActivityAttributes>.activities.filter { activity in
            activity.activityState != .active || activity.content.state.finished != nil || !tracked.contains(activity.attributes.session)
        }
        for activity in done { pending[activity.attributes.session] = nil }
        Task { for activity in done { await activity.end(nil, dismissalPolicy: .immediate) } }
    }

    // Runs on willTerminate: the process is about to die, so block briefly until the end calls reach ActivityKit.
    nonisolated static func endAllBeforeExit() {
        let activities = Activity<AgentActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    static var hasActive: Bool { Activity<AgentActivityAttributes>.activities.contains { $0.activityState == .active } }

    static func track(_ session: String) { tracked.insert(session) }

    static func answered(_ session: String) {
        guard let current = activity(for: session) else { return }
        var state = current.content.state
        guard state.phase == .waiting else { return }
        state.phase = .working
        state.permissionID = nil
        state.detail = "Continuing…"
        pending[session] = state
        flush(session, activity: current)
    }

    static func close(_ session: String) {
        tracked.remove(session)
        pending[session] = nil
        let activities = Activity<AgentActivityAttributes>.activities.filter { $0.attributes.session == session }
        Task { for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) } }
    }

    static func sync(session: String, chat: AgentChat, mac: String) {
        guard isEnabled else { return }
        let current = activity(for: session)
        guard tracked.contains(session) || current != nil else { return }
        let state = makeState(chat, previous: current?.content.state)
        guard let current else {
            guard state.phase == .working || state.phase == .waiting, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let finished = Activity<AgentActivityAttributes>.activities.filter { $0.attributes.session == session }
            if !finished.isEmpty { Task { for old in finished { await old.end(nil, dismissalPolicy: .immediate) } } }
            let attributes = AgentActivityAttributes(session: session, title: chat.title, mac: mac)
            _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
            return
        }
        guard state != current.content.state else { return }
        pending[session] = state
        flush(session, activity: current)
    }

    private static func flush(_ session: String, activity: Activity<AgentActivityAttributes>) {
        guard !inFlight.contains(session), let state = pending.removeValue(forKey: session) else { return }
        inFlight.insert(session)
        Task { @MainActor in
            if state.finished != nil {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(15 * 60)))
            } else {
                await activity.update(ActivityContent(state: state, staleDate: staleDate))
            }
            inFlight.remove(session)
            if let next = self.activity(for: session) { flush(session, activity: next) } else { pending[session] = nil }
        }
    }

    private static var staleDate: Date { Date().addingTimeInterval(90) }

    private static func activity(for session: String) -> Activity<AgentActivityAttributes>? {
        Activity<AgentActivityAttributes>.activities.first { $0.attributes.session == session && $0.activityState == .active }
    }

    private static func makeState(_ chat: AgentChat, previous: State?) -> State {
        let tools = chat.items.filter { $0.kind == "tool" }
        let phase: State.Phase
        if !chat.state.pending.isEmpty {
            phase = .waiting
        } else if chat.state.busy {
            phase = .working
        } else if chat.state.error != nil {
            phase = .failed
        } else if !chat.state.running {
            phase = .stopped
        } else {
            phase = .done
        }
        let started = previous?.started ?? Date()
        let finished: Date? = (phase == .working || phase == .waiting) ? nil : (previous?.finished ?? Date())
        return State(phase: phase, detail: detail(chat, phase: phase), steps: tools.count, started: started, finished: finished, permissionID: phase == .waiting ? chat.state.pending.first?.id : nil)
    }

    private static func detail(_ chat: AgentChat, phase: State.Phase) -> String {
        if let permission = chat.state.pending.first { return "\(permission.tool): \(permission.summary)" }
        if phase == .failed, let error = chat.state.error { return firstLine(error) }
        if phase == .working {
            if let tool = chat.items.last(where: { $0.kind == "tool" && $0.status == "running" }) {
                let text = firstLine(tool.text)
                return text.isEmpty ? (tool.tool ?? "Tool") : "\(tool.tool ?? "Tool") · \(text)"
            }
            if let status = chat.state.status, !status.isEmpty { return firstLine(status) }
            return "Thinking…"
        }
        if let text = chat.items.last(where: { $0.kind == "text" }) { return firstLine(text.text) }
        return phase == .stopped ? "The session stopped on the Mac" : "Finished"
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.trimmingCharacters(in: .whitespaces).prefix(90))
    }
}
