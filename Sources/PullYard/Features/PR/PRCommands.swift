import SwiftUI

struct PRActions {
    let ref: ItemRef
    let number: Int
    let isOpen: Bool
    let canReview: Bool
    let canMerge: Bool
    let hasFailing: Bool
    let unviewed: Int
    let writeReview: () -> Void
    let approve: () -> Void
    let requestChanges: () -> Void
    let merge: () -> Void
    let fixWithAgent: () -> Void
    let fixChecks: () -> Void
    let rerunFailed: () -> Void
    let markAllViewed: () -> Void
    let openInBrowser: () -> Void
    let copyLink: () -> Void
    let copyCheckout: () -> Void
}

extension FocusedValues {
    @Entry var prActions: PRActions?
}

struct PullRequestCommands: View {
    @FocusedValue(\.prActions) private var pr
    let app: AppModel

    var body: some View {
        Button("Write Review…") { pr?.writeReview() }
            .keyboardShortcut(AppCommand.writeReview)
            .disabled(pr?.isOpen != true)
        Button("Approve") { pr?.approve() }
            .keyboardShortcut(AppCommand.approve)
            .disabled(pr?.isOpen != true || pr?.canReview != true)
        Button("Request Changes…") { pr?.requestChanges() }
            .disabled(pr?.isOpen != true || pr?.canReview != true)
        Button("Merge…") { pr?.merge() }
            .keyboardShortcut(AppCommand.merge)
            .disabled(pr?.canMerge != true)
        Divider()
        Menu("Fix with Agent") {
            Button("Review Comments…") { pr?.fixWithAgent() }
                .keyboardShortcut(AppCommand.fixComments)
            Button("Failing Checks…") { pr?.fixChecks() }
                .disabled(pr?.hasFailing != true)
        }
        .disabled(pr?.isOpen != true)
        Button("Re-run Failed Checks") { pr?.rerunFailed() }
            .disabled(pr?.hasFailing != true)
        Button("Mark All Files Viewed") { pr?.markAllViewed() }
            .disabled((pr?.unviewed ?? 0) == 0)
        Divider()
        Button("Open in Browser") { pr?.openInBrowser() }
            .keyboardShortcut(AppCommand.openInBrowser)
            .disabled(pr == nil)
        Button("Copy Link") { pr?.copyLink() }
            .disabled(pr == nil)
        Button("Copy Checkout Command") { pr?.copyCheckout() }
            .disabled(pr == nil)
        Divider()
        Button("Next in Queue") { app.openQueue(step: 1) }
            .keyboardShortcut(AppCommand.nextInQueue)
            .disabled(app.reviewRequests.isEmpty || app.phase != .loggedIn)
        Button("Previous in Queue") { app.openQueue(step: -1) }
            .keyboardShortcut(AppCommand.previousInQueue)
            .disabled(app.reviewRequests.isEmpty || app.phase != .loggedIn)
    }
}
