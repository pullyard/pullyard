import ActivityKit
import Foundation

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case working, waiting, done, stopped, failed }

        var phase: Phase
        var detail: String
        var steps: Int
        var started: Date
        var finished: Date?

        var label: String {
            switch phase {
            case .working: "Working"
            case .waiting: "Needs you"
            case .done: "Done"
            case .stopped: "Stopped"
            case .failed: "Failed"
            }
        }
    }

    let session: String
    let title: String
    let mac: String
}
