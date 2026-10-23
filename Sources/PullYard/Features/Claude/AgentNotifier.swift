import AppKit
import UserNotifications

extension Notification.Name {
    static let openAgentTab = Notification.Name("PullYard.openAgentTab")
}

@MainActor
enum AgentNotifier {
    static let enabledKey = "agents.notify"
    static let prefix = "agent-"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func post(tab: UUID, title: String, body: String) {
        guard enabled else { return }
        UpdateNotifier.shared.install()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = "agents"
            center.add(UNNotificationRequest(identifier: prefix + tab.uuidString + "-" + UUID().uuidString.prefix(6), content: content, trigger: nil))
        }
    }

    static func tabID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(prefix.count).prefix(36)))
    }

    static func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    static func snippet(_ text: String?) -> String {
        guard let text else { return "" }
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}
