import Foundation

@Observable
@MainActor
final class AgentUsageLedger {
    struct Day: Codable, Equatable {
        var cost: Double = 0
        var turns: Int = 0
    }

    static let shared = AgentUsageLedger(file: NSClassFromString("XCTestCase") == nil ? defaultFile : nil)

    static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullYard", isDirectory: true)
            .appendingPathComponent("agent-usage.json")
    }

    private(set) var days: [String: Day] = [:]
    private let file: URL?
    private let keep = 120

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = saved
        }
    }

    nonisolated static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func record(cost: Double, at date: Date = Date(), calendar: Calendar = .current) {
        let k = Self.key(date, calendar: calendar)
        var day = days[k] ?? Day()
        day.cost += max(cost, 0)
        day.turns += 1
        days[k] = day
        if days.count > keep {
            for old in days.keys.sorted().dropLast(keep) { days[old] = nil }
        }
        save()
    }

    func total(lastDays n: Int, now: Date = Date(), calendar: Calendar = .current) -> Day {
        var sum = Day()
        for offset in 0..<max(n, 1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now), let day = days[Self.key(date, calendar: calendar)] else { continue }
            sum.cost += day.cost
            sum.turns += day.turns
        }
        return sum
    }

    func clear() {
        days = [:]
        save()
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(days) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
