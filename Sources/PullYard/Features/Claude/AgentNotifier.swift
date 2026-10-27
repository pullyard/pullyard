import AppKit
import UserNotifications

extension Notification.Name {
    static let openAgentTab = Notification.Name("PullYard.openAgentTab")
}

@MainActor
enum AgentNotifier {
    nonisolated static let enabledKey = "agents.notify"
    static let prefix = "agent-"

    static func post(tab: UUID, kind: NotifyKind, title: String, body: String) {
        guard kind.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "agents"
        SystemNotifications.deliver(identifier: prefix + tab.uuidString + "-" + UUID().uuidString.prefix(6), content: content)
    }

    static func tabID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count).prefix(36)))
    }

    static func setBadge(_ count: Int) {
        DockBadge.set(agents: count)
    }

    static func snippet(_ text: String?) -> String {
        guard let text else { return "" }
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}
