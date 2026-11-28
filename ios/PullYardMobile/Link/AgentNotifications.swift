import UIKit
import UserNotifications

@MainActor
enum AgentNotifier {
    static let category = "PULLYARD_AGENT"
    static let allowAction = "AGENT_ALLOW"
    static let denyAction = "AGENT_DENY"
    static let replyAction = "AGENT_REPLY"
    static let enabledKey = "agents.notify"

    private static var notified: Set<String> = []

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    nonisolated static var notificationCategory: UNNotificationCategory {
        let allow = UNNotificationAction(identifier: allowAction, title: L("Allow"), options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyAction, title: L("Deny"), options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: L("Reply"), options: [.authenticationRequired], textInputButtonTitle: L("Send"), textInputPlaceholder: L("Tell the agent what to do"))
        return UNNotificationCategory(identifier: category, actions: [allow, deny, reply], intentIdentifiers: [], options: [])
    }

    static func identifier(session: String, request: String) -> String { "agent-\(session)-\(request)" }

    static func prepare() {
        guard isEnabled else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
        }
    }

    static func pendingKeys(_ sessions: [PYLinkSession]) -> [String: (PYLinkSession, PYLinkPermission)] {
        var result: [String: (PYLinkSession, PYLinkPermission)] = [:]
        for session in sessions {
            guard let permission = session.pending else { continue }
            result[identifier(session: session.id, request: permission.id)] = (session, permission)
        }
        return result
    }

    static func fresh(_ sessions: [PYLinkSession], notified: Set<String>, viewing: String?, appActive: Bool) -> [String] {
        pendingKeys(sessions).filter { key, value in
            !notified.contains(key) && !(appActive && value.0.id == viewing)
        }.map(\.key).sorted()
    }

    static func update(_ sessions: [PYLinkSession], titles: PYLinkPrefs, viewing: String?, mac: String) {
        let pending = pendingKeys(sessions)
        let resolved = notified.subtracting(pending.keys)
        if !resolved.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(resolved))
            notified.subtract(resolved)
        }
        guard isEnabled else { return }
        let active = UIApplication.shared.applicationState == .active
        for key in fresh(sessions, notified: notified, viewing: viewing, appActive: active) {
            guard let (session, permission) = pending[key] else { continue }
            notified.insert(key)
            let content = UNMutableNotificationContent()
            content.title = String(format: L("Agent needs you · %@"), titles.title(for: session))
            content.subtitle = permission.tool
            content.body = [permission.summary, permission.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            content.sound = .default
            content.categoryIdentifier = category
            content.threadIdentifier = "agent-\(session.id)"
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["session": session.id, "request": permission.id, "url": "pullyard://agent/\(session.id)", "mac": mac]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    static func handle(_ response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let session = info["session"] as? String else { return }
        let request = info["request"] as? String
        let link = LinkClient.shared
        do {
            switch response.actionIdentifier {
            case allowAction, denyAction:
                guard let request else { return }
                try await link.respondRemote(session: session, requestID: request, allow: response.actionIdentifier == allowAction)
            case replyAction:
                let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return }
                try await link.reply(text, to: session, requestID: request)
            default:
                if let raw = info["url"] as? String, let url = URL(string: raw) { _ = await UIApplication.shared.open(url) }
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        } catch {
            let content = UNMutableNotificationContent()
            content.title = L("Couldn't reach the agent")
            content.body = error.localizedDescription
            content.threadIdentifier = "agent-\(session)"
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "agent-result-\(UUID().uuidString)", content: content, trigger: nil))
        }
    }
}
