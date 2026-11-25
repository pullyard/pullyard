import ActivityKit
import Foundation

struct CIActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var passed: Int
        var failed: Int
        var running: Int
        var skipped: Int
        var updated: Date

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
