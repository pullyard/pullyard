import AppKit
import UserNotifications

extension Notification.Name {
    static let openActivity = Notification.Name("PullYard.openActivity")
}

enum NotifyKind: String, CaseIterable, Identifiable {
    case reviewRequest, ciFailed, reviewDecision, agentInput, agentFinished

    var id: String { rawValue }
    var key: String { "notify." + rawValue }

    var title: String {
        switch self {
        case .reviewRequest: return "New review requests"
        case .ciFailed: return "Checks failed on my pull requests"
        case .reviewDecision: return "My pull requests approved or changes requested"
        case .agentInput: return "Agent needs permission or an answer"
        case .agentFinished: return "Agent finished"
        }
    }

    var isAgent: Bool { self == .agentInput || self == .agentFinished }

    var enabled: Bool {
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: key) as? Bool { return value }
        if isAgent, let legacy = defaults.object(forKey: AgentNotifier.enabledKey) as? Bool { return legacy }
        return true
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
    }
}

struct ActivityItem: Equatable {
    let id: String
    let ref: ItemRef
    let title: String
    let updatedAt: Date
    let ciState: String?
    let reviewDecision: String?
}

extension ActivityItem {
    init(_ item: SearchItem) {
        self.init(id: item.id, ref: item.ref, title: item.title, updatedAt: item.updatedAt, ciState: item.ciState, reviewDecision: item.reviewDecision)
    }
}

enum ActivityEvent: Equatable {
    case reviewRequested(ActivityItem)
    case ciFailed(ActivityItem)
    case approved(ActivityItem)
    case changesRequested(ActivityItem)

    var item: ActivityItem {
        switch self {
        case .reviewRequested(let i), .ciFailed(let i), .approved(let i), .changesRequested(let i): return i
        }
    }

    var kind: NotifyKind {
        switch self {
        case .reviewRequested: return .reviewRequest
        case .ciFailed: return .ciFailed
        case .approved, .changesRequested: return .reviewDecision
        }
    }

    var key: String {
        let tag: String
        switch self {
        case .reviewRequested: tag = "rr"
        case .ciFailed: tag = "ci"
        case .approved: tag = "approved"
        case .changesRequested: tag = "changes"
        }
        return "\(tag)|\(item.id)|\(Int(item.updatedAt.timeIntervalSince1970))"
    }

    var headline: String {
        switch self {
        case .reviewRequested: return "Review requested"
        case .ciFailed: return "Checks failed"
        case .approved: return "Approved"
        case .changesRequested: return "Changes requested"
        }
    }
}

struct ActivityTracker {
    static let failing: Set<String> = ["FAILURE", "ERROR"]

    private var reviewsPrimed = false
    private var minePrimed = false
    private var reviewIDs: Set<String> = []
    private var reviewTotal = 0
    private var mineIDs: Set<String> = []
    private var ci: [String: String] = [:]
    private var decisions: [String: String] = [:]

    mutating func update(reviews: [ActivityItem]?, reviewTotal total: Int, mine: [ActivityItem]?) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        if let reviews {
            if reviewsPrimed {
                let fresh = reviews.filter { !reviewIDs.contains($0.id) }
                if total > reviews.count {
                    events += fresh.prefix(max(0, total - reviewTotal)).map(ActivityEvent.reviewRequested)
                } else {
                    events += fresh.map(ActivityEvent.reviewRequested)
                }
            }
            reviewIDs = Set(reviews.map(\.id))
            reviewTotal = total
            reviewsPrimed = true
        }
        if let mine {
            if minePrimed {
                for item in mine where mineIDs.contains(item.id) {
                    if let state = item.ciState, Self.failing.contains(state), !Self.failing.contains(ci[item.id] ?? "") {
                        events.append(.ciFailed(item))
                    }
                    if item.reviewDecision != decisions[item.id] {
                        switch item.reviewDecision {
                        case "APPROVED": events.append(.approved(item))
                        case "CHANGES_REQUESTED": events.append(.changesRequested(item))
                        default: break
                        }
                    }
                }
            }
            mineIDs = Set(mine.map(\.id))
            ci = Dictionary(mine.compactMap { i in i.ciState.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
            decisions = Dictionary(mine.compactMap { i in i.reviewDecision.map { (i.id, $0) } }, uniquingKeysWith: { a, _ in a })
            minePrimed = true
        }
        return events
    }
}

struct RecentEvents {
    private(set) var keys: [String]
    let limit: Int

    init(keys: [String] = [], limit: Int = 300) {
        self.keys = Array(keys.suffix(limit))
        self.limit = limit
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    mutating func insert(_ key: String) -> Bool {
        guard !keys.contains(key) else { return false }
        keys.append(key)
        if keys.count > limit { keys.removeFirst(keys.count - limit) }
        return true
    }
}

struct ActivityTarget: Sendable {
    static let urlKey = "activity.url"
    static let repoKey = "activity.repo"
    static let numberKey = "activity.number"
    static let accountKey = "activity.account"

    let url: String
    let repo: String
    let number: Int
    let account: String?

    init(url: String, repo: String, number: Int, account: String?) {
        self.url = url
        self.repo = repo
        self.number = number
        self.account = account
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let url = userInfo[Self.urlKey] as? String, let repo = userInfo[Self.repoKey] as? String, let number = userInfo[Self.numberKey] as? Int else { return nil }
        self.init(url: url, repo: repo, number: number, account: userInfo[Self.accountKey] as? String)
    }

    var userInfo: [String: Any] {
        var info: [String: Any] = [Self.urlKey: url, Self.repoKey: repo, Self.numberKey: number]
        if let account { info[Self.accountKey] = account }
        return info
    }
}

@MainActor
enum SystemNotifications {
    static func deliver(identifier: String, content: UNMutableNotificationContent) {
        UpdateNotifier.shared.install()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        }
    }

    static func requestAccess() async -> Bool {
        UpdateNotifier.shared.install()
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
final class ActivityNotifier {
    static let shared = ActivityNotifier()
    static let recentKey = "notify.recent"
    static let prefix = "activity-"

    private var tracker = ActivityTracker()
    private var scope: String?
    private var recent = RecentEvents(keys: UserDefaults.standard.stringArray(forKey: recentKey) ?? [])

    func reset() {
        tracker = ActivityTracker()
        scope = nil
    }

    func observe(account: String?, reviews: [SearchItem]?, reviewTotal: Int, mine: [SearchItem]?) {
        if scope != account {
            tracker = ActivityTracker()
            scope = account
        }
        let events = tracker.update(reviews: reviews?.filter(\.isPR).map(ActivityItem.init), reviewTotal: reviewTotal, mine: mine?.filter(\.isPR).map(ActivityItem.init))
        var changed = false
        for event in events where event.kind.enabled {
            guard recent.insert(event.key) else { continue }
            changed = true
            post(event, account: account)
        }
        if changed { UserDefaults.standard.set(recent.keys, forKey: Self.recentKey) }
    }

    private func post(_ event: ActivityEvent, account: String?) {
        let item = event.item
        let content = UNMutableNotificationContent()
        content.title = event.headline + " · " + item.ref.title
        content.body = item.title
        content.sound = .default
        content.threadIdentifier = item.ref.repo.full
        content.userInfo = ActivityTarget(url: item.id, repo: item.ref.repo.full, number: item.ref.number, account: account).userInfo
        SystemNotifications.deliver(identifier: Self.prefix + event.key, content: content)
    }
}

@MainActor
enum DockBadge {
    static let enabledKey = "dock.badge"
    static let agentsKey = "dock.badge.agents"

    private static var reviews = 0
    private static var agents = 0

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var includesAgents: Bool { UserDefaults.standard.object(forKey: agentsKey) as? Bool ?? true }

    static func set(reviews count: Int) {
        reviews = count
        apply()
    }

    static func set(agents count: Int) {
        agents = count
        apply()
    }

    nonisolated static func count(reviews: Int, agents: Int, enabled: Bool, includesAgents: Bool) -> Int {
        guard enabled else { return 0 }
        return max(0, reviews) + (includesAgents ? max(0, agents) : 0)
    }

    static func apply() {
        guard let app = NSApp as NSApplication? else { return }
        let total = count(reviews: reviews, agents: agents, enabled: enabled, includesAgents: includesAgents)
        let label = total > 0 ? "\(total)" : nil
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }
}
