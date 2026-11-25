import AppIntents
import Foundation

struct OpenReviewQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Open review queue"
    static var description = IntentDescription("Opens PullYard on the pull requests waiting for your review.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLink.set(URL(string: "pullyard://queue")!)
        NotificationCenter.default.post(name: .pullyardPendingLink, object: nil)
        return .result()
    }
}

struct ReviewSummaryIntent: AppIntent {
    static var title: LocalizedStringResource = "What's waiting for my review"
    static var description = IntentDescription("Tells you how many pull requests are waiting for your review.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot: WidgetSnapshot
        if let fresh = try? await WidgetFetcher.fetch() { snapshot = fresh } else if let cached = WidgetSnapshot.load() { snapshot = cached } else {
            return .result(dialog: "PullYard couldn't reach GitHub. Open the app and sign in.")
        }
        if snapshot.needsReview == 0 { return .result(dialog: "Nothing is waiting for your review. Calm waters.") }
        let titles = snapshot.items.prefix(3).map { "\($0.title) in \($0.repo)" }.joined(separator: "; ")
        return .result(dialog: "\(snapshot.needsReview) pull request\(snapshot.needsReview == 1 ? " is" : "s are") waiting for your review: \(titles).")
    }
}

struct OpenPullRequestIntent: AppIntent {
    static var title: LocalizedStringResource = "Open pull request"
    static var description = IntentDescription("Opens a GitHub pull request link in PullYard.")
    static var openAppWhenRun = true

    @Parameter(title: "Link")
    var link: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingLink.set(link)
        NotificationCenter.default.post(name: .pullyardPendingLink, object: nil)
        return .result()
    }
}

struct PullYardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReviewSummaryIntent(), phrases: ["What's waiting for my review in \(.applicationName)", "Check my reviews in \(.applicationName)"], shortTitle: "Waiting for review", systemImageName: "eye")
        AppShortcut(intent: OpenReviewQueueIntent(), phrases: ["Open my review queue in \(.applicationName)", "Show reviews in \(.applicationName)"], shortTitle: "Review queue", systemImageName: "tray.full")
        AppShortcut(intent: OpenPullRequestIntent(), phrases: ["Open a pull request in \(.applicationName)"], shortTitle: "Open pull request", systemImageName: "arrow.triangle.pull")
    }
}

extension Notification.Name {
    static let pullyardPendingLink = Notification.Name("PullYardPendingLink")
}
