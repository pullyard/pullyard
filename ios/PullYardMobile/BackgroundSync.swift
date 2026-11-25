import BackgroundTasks
import UIKit
import UserNotifications
import WidgetKit

enum WidgetBridge {
    static func publish(reviews: [PullRequest], mine: [PullRequest], unread: Int) {
        let items = reviews.sorted { $0.updatedAt > $1.updatedAt }.prefix(5).compactMap { pull -> WidgetItem? in
            guard let key = pull.key else { return nil }
            return WidgetItem(repo: key.repo, number: key.number, title: pull.title, author: pull.user?.login, ci: pull.checkState)
        }
        WidgetSnapshot(updated: .now, needsReview: reviews.count, myOpen: mine.count, unread: unread, items: Array(items)).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func clear() {
        WidgetSnapshot.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

enum NotifyPrefs {
    static let enabled = "mobile.notify.enabled"
    static let reviews = "mobile.notify.reviews"
    static let mentions = "mobile.notify.mentions"
    static let myReviews = "mobile.notify.myReviews"
    static let ci = "mobile.notify.ci"
    static let badge = "mobile.notify.badge"

    static func flag(_ key: String, default value: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

struct NotifyBaseline: Codable, Equatable {
    struct MineState: Codable, Equatable {
        var decision: String?
        var ci: String?
    }
    var reviewKeys: Set<String> = []
    var notifiedThreads: Set<String> = []
    var mine: [String: MineState] = [:]
}

struct LocalAlert: Equatable {
    let id: String
    let title: String
    let body: String
    let url: URL?
    let thread: String
    var notificationID: String? = nil
}

enum BackgroundSync {
    static let taskID = "com.pullyard.mobile.refresh"
    static let category = "PULLYARD_ITEM"
    static let markReadAction = "MARK_READ"
    private static let store = LocalStore.support
    private static let baselineFile = "notify-baseline.json"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refresh)
        }
        let markRead = UNNotificationAction(identifier: markReadAction, title: "Mark as read")
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: category, actions: [open, markRead], intentIdentifiers: [])])
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    static func schedule() {
        guard NotifyPrefs.flag(NotifyPrefs.enabled, default: false) || NotifyPrefs.flag(NotifyPrefs.badge, default: false) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskID)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let ok = await check()
            task.setTaskCompleted(success: ok)
        }
        task.expirationHandler = { work.cancel() }
    }

    static func check() async -> Bool {
        guard case let .found(token) = CredentialVault().read() else { return false }
        let client = GitHubClient(token: token)
        do {
            let reviews = try await client.pullRequests(list: PRListKey(queue: .needsMyReview, status: .open), cursor: nil, perPage: 50)
            let mine = try await client.pullRequests(list: PRListKey(queue: .createdByMe, status: .open), cursor: nil, perPage: 50)
            let notifications = (try? await client.notifications()) ?? []
            let previous = loadBaseline()
            let (alerts, next) = diff(previous: previous, reviews: reviews.items, mine: mine.items, notifications: notifications)
            if NotifyPrefs.flag(NotifyPrefs.enabled, default: false) {
                for alert in alerts { await post(alert) }
            }
            saveBaseline(next)
            await updateBadge(unread: notifications.filter(\.unread).count)
            WidgetBridge.publish(reviews: reviews.items, mine: mine.items, unread: notifications.filter(\.unread).count)
            return true
        } catch {
            return false
        }
    }

    static func updateBaseline(reviews: [PullRequest], mine: [PullRequest], notifications: [GHNotification]) {
        let (_, next) = diff(previous: loadBaseline(), reviews: reviews, mine: mine, notifications: notifications)
        saveBaseline(next)
        WidgetBridge.publish(reviews: reviews, mine: mine, unread: notifications.filter(\.unread).count)
        Task { await updateBadge(unread: notifications.filter(\.unread).count) }
    }

    static func diff(previous: NotifyBaseline?, reviews: [PullRequest], mine: [PullRequest], notifications: [GHNotification]) -> ([LocalAlert], NotifyBaseline) {
        var next = NotifyBaseline()
        var alerts: [LocalAlert] = []
        let enabledReviews = NotifyPrefs.flag(NotifyPrefs.reviews)
        let enabledMentions = NotifyPrefs.flag(NotifyPrefs.mentions)
        let enabledMine = NotifyPrefs.flag(NotifyPrefs.myReviews)
        let enabledCI = NotifyPrefs.flag(NotifyPrefs.ci)

        for pull in reviews {
            guard let key = pull.key else { continue }
            next.reviewKeys.insert(key.id)
            if let previous, enabledReviews, !previous.reviewKeys.contains(key.id) {
                alerts.append(LocalAlert(id: "review-\(key.id)", title: "Review requested · \(key.repo)", body: "\(pull.user?.login ?? "Someone"): \(pull.title)", url: URL(string: "pullyard://pull/\(key.repo)/\(key.number)"), thread: key.repo))
            }
        }

        for pull in mine {
            guard let key = pull.key else { continue }
            let state = NotifyBaseline.MineState(decision: pull.reviewDecision, ci: pull.checkState)
            next.mine[key.id] = state
            guard let previous, let old = previous.mine[key.id] else { continue }
            if enabledMine, state.decision != old.decision, let decision = state.decision, decision == "APPROVED" || decision == "CHANGES_REQUESTED" {
                let approved = decision == "APPROVED"
                alerts.append(LocalAlert(id: "decision-\(key.id)-\(decision)", title: approved ? "Approved · \(key.repo)#\(key.number)" : "Changes requested · \(key.repo)#\(key.number)", body: pull.title, url: URL(string: "pullyard://pull/\(key.repo)/\(key.number)"), thread: key.repo))
            }
            if enabledCI, state.ci != old.ci, let ci = state.ci, ci == "FAILURE" || ci == "ERROR" {
                alerts.append(LocalAlert(id: "ci-\(key.id)", title: "Checks failed · \(key.repo)#\(key.number)", body: pull.title, url: URL(string: "pullyard://pull/\(key.repo)/\(key.number)"), thread: key.repo))
            }
        }

        for item in notifications where item.unread {
            next.notifiedThreads.insert(item.id)
            guard let previous, enabledMentions, !previous.notifiedThreads.contains(item.id), item.reason == "mention" || item.reason == "team_mention" else { continue }
            let url = item.pullKey.map { URL(string: "pullyard://pull/\($0.repo)/\($0.number)") } ?? item.webURL
            alerts.append(LocalAlert(id: "mention-\(item.id)", title: "Mentioned · \(item.repository.fullName)", body: item.subject.title, url: url ?? nil, thread: item.repository.fullName, notificationID: item.id))
        }
        return (alerts, next)
    }

    private static func post(_ alert: LocalAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.thread
        content.categoryIdentifier = category
        var info: [String: String] = [:]
        if let url = alert.url { info["url"] = url.absoluteString }
        if let id = alert.notificationID { info["notificationID"] = id }
        content.userInfo = info
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }

    static func updateBadge(unread: Int) async {
        let count = NotifyPrefs.flag(NotifyPrefs.badge, default: false) ? unread : 0
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    private static func loadBaseline() -> NotifyBaseline? { store.readJSON(NotifyBaseline.self, baselineFile) }
    private static func saveBaseline(_ baseline: NotifyBaseline) { store.writeJSON(baseline, baselineFile) }
    static func reset() { store.remove(baselineFile); WidgetBridge.clear(); Task { await updateBadge(unread: 0) } }
}

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == BackgroundSync.markReadAction {
            guard let id = info["notificationID"] as? String, case let .found(token) = CredentialVault().read() else { return }
            try? await GitHubClient(token: token).markRead(id)
            return
        }
        guard let raw = info["url"] as? String, let url = URL(string: raw) else { return }
        await MainActor.run { UIApplication.shared.open(url) }
    }
}
