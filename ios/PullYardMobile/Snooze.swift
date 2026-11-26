import CoreSpotlight
import AppIntents
import SwiftUI

enum SnoozeStore {
    private static let key = "mobile.snoozed"
    private static var defaults: UserDefaults { UserDefaults(suiteName: WidgetSnapshot.groupID) ?? .standard }

    static func all() -> [String: Date] {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.compactMapValues { value in
            let date = Date(timeIntervalSince1970: value)
            return date > .now ? date : nil
        }
    }

    static func save(_ items: [String: Date]) {
        defaults.set(items.mapValues(\.timeIntervalSince1970), forKey: key)
    }

    static func isSnoozed(_ key: PRKey?) -> Bool {
        guard let key else { return false }
        return all()[key.id] != nil
    }

    static func presets(now: Date = .now) -> [(String, Date)] {
        let calendar = Calendar.current
        let inHour = now.addingTimeInterval(3_600)
        var evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? inHour
        if evening <= now { evening = calendar.date(byAdding: .day, value: 1, to: evening) ?? inHour }
        let tomorrow = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? inHour
        let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) ?? tomorrow
        return [("For an hour", inHour), ("Until this evening", evening), ("Until tomorrow", tomorrow), ("Until next week", monday)]
    }
}

struct SnoozeMenu: View {
    let key: PRKey
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isSnoozed(key) {
            Button { withAnimation { model.unsnooze(key) } } label: { Label("Unsnooze", systemImage: "bell") }
        } else {
            Menu {
                ForEach(SnoozeStore.presets(), id: \.0) { title, date in
                    Button { withAnimation { model.snooze(key, until: date) } } label: {
                        Text("\(L(title)) · \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            } label: { Label("Snooze", systemImage: "moon.zzz") }
        }
    }
}

enum FocusSettings {
    private static var defaults: UserDefaults { UserDefaults(suiteName: WidgetSnapshot.groupID) ?? .standard }
    static var pinnedOnly: Bool { defaults.bool(forKey: "focus.pinnedOnly") }
    static var pauseNotifications: Bool { defaults.bool(forKey: "focus.pauseNotifications") }

    static func apply(pinnedOnly: Bool, pauseNotifications: Bool) {
        defaults.set(pinnedOnly, forKey: "focus.pinnedOnly")
        defaults.set(pauseNotifications, forKey: "focus.pauseNotifications")
    }
}

struct PullYardFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "PullYard"
    static var description = IntentDescription("Choose what PullYard shows while this Focus is on.")

    @Parameter(title: "Only pinned projects", default: false)
    var pinnedOnly: Bool

    @Parameter(title: "Pause PullYard notifications", default: false)
    var pauseNotifications: Bool

    var displayRepresentation: DisplayRepresentation {
        var parts: [String] = []
        if pinnedOnly { parts.append("Pinned projects only") }
        if pauseNotifications { parts.append("Notifications paused") }
        return DisplayRepresentation(title: "PullYard", subtitle: LocalizedStringResource(stringLiteral: parts.isEmpty ? "Everything" : parts.joined(separator: " · ")))
    }

    func perform() async throws -> some IntentResult {
        FocusSettings.apply(pinnedOnly: pinnedOnly, pauseNotifications: pauseNotifications)
        await MainActor.run { NotificationCenter.default.post(name: .pullyardFocusChanged, object: nil) }
        return .result()
    }
}

extension Notification.Name {
    static let pullyardFocusChanged = Notification.Name("PullYardFocusChanged")
}

enum SpotlightIndexer {
    static let domain = "com.pullyard.pulls"

    static func index(_ pulls: [PullRequest]) {
        let items = pulls.prefix(200).compactMap { pull -> CSSearchableItem? in
            guard let key = pull.key else { return nil }
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = pull.title
            attributes.contentDescription = "\(key.repo) #\(key.number)\(pull.user.map { " · @\($0.login)" } ?? "")"
            attributes.keywords = [key.repo, String(key.repo.split(separator: "/").last ?? ""), "#\(key.number)", pull.user?.login].compactMap { $0 }
            let item = CSSearchableItem(uniqueIdentifier: key.id, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = Date().addingTimeInterval(14 * 86_400)
            return item
        }
        CSSearchableIndex.default().indexSearchableItems(Array(items))
    }

    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    static func route(from activity: NSUserActivity) -> Route? {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        let parts = identifier.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return .pull(PRKey(repo: String(parts[0]), number: number))
    }
}
