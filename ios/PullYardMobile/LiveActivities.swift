import ActivityKit
import Foundation

enum LiveActivityManager {
    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func state(for checks: [CheckRun]) -> CIActivityAttributes.ContentState {
        CIActivityAttributes.ContentState(passed: checks.filter(\.isSuccess).count, failed: checks.filter(\.isFailure).count, running: checks.filter(\.isPending).count, skipped: checks.filter(\.isSkipped).count, updated: .now)
    }

    static func activity(for key: PRKey) -> Activity<CIActivityAttributes>? {
        Activity<CIActivityAttributes>.activities.first { $0.attributes.repo == key.repo && $0.attributes.number == key.number }
    }

    static func isFollowing(_ key: PRKey) -> Bool { activity(for: key) != nil }

    static func start(_ key: PRKey, title: String, checks: [CheckRun]) throws {
        if activity(for: key) != nil { return }
        let attributes = CIActivityAttributes(repo: key.repo, number: key.number, title: title)
        _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state(for: checks), staleDate: Date().addingTimeInterval(30 * 60)))
    }

    static func update(_ key: PRKey, checks: [CheckRun]) async {
        guard let activity = activity(for: key) else { return }
        guard activity.activityState == .active else { return }
        let next = state(for: checks)
        await activity.update(ActivityContent(state: next, staleDate: Date().addingTimeInterval(30 * 60)))
    }

    static func docked(_ key: PRKey, title: String, checks: [CheckRun]) async {
        guard isAvailable else { return }
        var docked = state(for: checks)
        docked.merged = true
        let content = ActivityContent(state: docked, staleDate: nil)
        let live: Activity<CIActivityAttributes>?
        if let existing = Activity<CIActivityAttributes>.activities.first(where: { $0.attributes.repo == key.repo && $0.attributes.number == key.number && $0.activityState == .active }) {
            await existing.update(content, alertConfiguration: nil)
            live = existing
        } else {
            for old in Activity<CIActivityAttributes>.activities where old.attributes.repo == key.repo && old.attributes.number == key.number {
                await old.end(nil, dismissalPolicy: .immediate)
            }
            live = try? Activity.request(attributes: CIActivityAttributes(repo: key.repo, number: key.number, title: title), content: content)
        }
        try? await Task.sleep(for: .seconds(8))
        await live?.end(content, dismissalPolicy: .after(Date().addingTimeInterval(10 * 60)))
    }

    static func stop(_ key: PRKey) async {
        await activity(for: key)?.end(nil, dismissalPolicy: .immediate)
    }

    static func refreshAll(using client: GitHubClient) async {
        for activity in Activity<CIActivityAttributes>.activities {
            let key = PRKey(repo: activity.attributes.repo, number: activity.attributes.number)
            guard let pull = try? await client.pullRequest(key), !pull.head.sha.isEmpty,
                  let checks = try? await client.checks(key, sha: pull.head.sha) else { continue }
            await update(key, checks: checks)
        }
    }
}
