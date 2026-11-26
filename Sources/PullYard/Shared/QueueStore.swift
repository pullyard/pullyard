import Foundation
import Observation

@Observable
@MainActor
final class QueueStore {
    static let shared = QueueStore()

    private static let snoozeKey = "queue.snoozed"
    private static let seenKey = "queue.seen"
    private static let sinceKey = "queue.since"

    private(set) var snoozed: [String: Date]
    private(set) var seen: [String: Date]
    private let since: Date

    private init() {
        let defaults = UserDefaults.standard
        snoozed = (defaults.dictionary(forKey: Self.snoozeKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        seen = (defaults.dictionary(forKey: Self.seenKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        if let stored = defaults.object(forKey: Self.sinceKey) as? Double {
            since = Date(timeIntervalSince1970: stored)
        } else {
            since = Date()
            defaults.set(since.timeIntervalSince1970, forKey: Self.sinceKey)
        }
        snoozed = snoozed.filter { $0.value > Date() }
    }

    private static func key(_ ref: ItemRef) -> String { ref.title.lowercased() }

    func snoozedUntil(_ ref: ItemRef) -> Date? {
        guard let until = snoozed[Self.key(ref)], until > Date() else { return nil }
        return until
    }

    func snooze(_ ref: ItemRef, until: Date) {
        snoozed[Self.key(ref)] = until
        save()
    }

    func wake(_ ref: ItemRef) {
        snoozed[Self.key(ref)] = nil
        save()
    }

    func markSeen(_ ref: ItemRef) {
        seen[Self.key(ref)] = Date()
        if seen.count > 600 {
            let keep = seen.sorted { $0.value > $1.value }.prefix(400)
            seen = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        save()
    }

    func hasNews(_ item: SearchItem) -> Bool {
        if let last = seen[Self.key(item.ref)] { return item.updatedAt > last.addingTimeInterval(5) }
        return item.updatedAt > since
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(snoozed.mapValues(\.timeIntervalSince1970), forKey: Self.snoozeKey)
        defaults.set(seen.mapValues(\.timeIntervalSince1970), forKey: Self.seenKey)
    }

    static func presets(now: Date = Date()) -> [(title: String, date: Date)] {
        let cal = Calendar.current
        let hour = now.addingTimeInterval(3600)
        let tomorrow = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now) ?? now) ?? hour
        let monday = cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) ?? tomorrow
        return [("For an hour", hour), ("Until tomorrow", tomorrow), ("Until next week", monday)]
    }
}
