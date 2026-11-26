import ActivityKit
import Foundation

struct CIActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var passed: Int
        var failed: Int
        var running: Int
        var skipped: Int
        var updated: Date
        var merged: Bool?

        var isMerged: Bool { merged == true }
        var progress: Double {
            if isMerged { return 1 }
            guard total > 0 else { return 0.06 }
            return min(0.9, max(0.06, Double(passed + skipped) / Double(total) * 0.9))
        }
        var voyage: String {
            if isMerged { return "Docked · merged" }
            if failed > 0 { return failed == 1 ? "Storm · 1 check failing" : "Storm · \(failed) checks failing" }
            if running > 0 { return "Sailing · \(passed + skipped) of \(total) checks" }
            return total == 0 ? "Ready to dock" : "Ready to dock · all checks passed"
        }

        var total: Int { passed + failed + running + skipped }
        var isFinished: Bool { running == 0 }
        var headline: String {
            if failed > 0 { return running > 0 ? "\(failed) failing · \(running) running" : "\(failed) check\(failed == 1 ? "" : "s") failed" }
            if running > 0 { return "\(running) of \(total) running" }
            return "All checks passed"
        }
    }

    let repo: String
    let number: Int
    let title: String
}
