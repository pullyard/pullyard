import ActivityKit
import AppIntents
import Foundation

struct AgentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case working, waiting, done, stopped, failed }

        var phase: Phase
        var detail: String
        var steps: Int
        var started: Date
        var finished: Date?
        var permissionID: String?
    }

    let session: String
    let title: String
    let mac: String
}

enum AgentIntentBridge {
    nonisolated(unsafe) static var respond: ((String, String, Bool) async throws -> Void)?
}

struct AgentPermissionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer the agent"
    static var isDiscoverable = false

    @Parameter(title: "Session") var session: String
    @Parameter(title: "Request") var request: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}

    init(session: String, request: String, allow: Bool) {
        self.session = session
        self.request = request
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        try await AgentIntentBridge.respond?(session, request, allow)
        return .result()
    }
}
