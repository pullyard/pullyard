import SwiftUI
import UserNotifications

struct NextUpPanel: View {
    @Environment(AppModel.self) private var app

    private var reviews: [SearchItem] { Array(app.reviewRequests.prefix(3)) }

    private var attention: [SearchItem] {
        Array(app.myPRs.filter { item in
            ["FAILURE", "ERROR"].contains(item.ciState ?? "") || item.reviewDecision == "CHANGES_REQUESTED"
        }.prefix(3))
    }

    private var recent: [ItemRef] {
        var seen = Set<ItemRef>()
        let shown = Set((reviews + attention).map(\.ref))
        return app.recentRoutes.compactMap { ShortLink.ref(route: $0) }.filter { !shown.contains($0) && seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    var body: some View {
        let reviews = reviews, attention = attention, recent = recent
        if !reviews.isEmpty || !attention.isEmpty || !recent.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if !reviews.isEmpty {
                    card("Your turn", icon: "eye.fill", tint: .sySky) {
                        ForEach(reviews) { item in itemRow(item) }
                    }
                }
                if !attention.isEmpty {
                    card("Needs attention", icon: "exclamationmark.triangle.fill", tint: .syAmberInk) {
                        ForEach(attention) { item in itemRow(item) }
                    }
                }
                if !recent.isEmpty {
                    card("Recent", icon: "clock.arrow.circlepath", tint: .syMuted) {
                        ForEach(recent, id: \.self) { ref in
                            Button { app.open(.pr(ref)) } label: {
                                Text(ShortLink.make(ref))
                                    .font(.syCallout.monospaced())
                                    .foregroundStyle(Color.syText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverHighlight(radius: 6)
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 24)
        }
    }

    private func card<Content: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.sy(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(tint)
            content()
        }
        .padding(12)
        .frame(maxWidth: 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.syLine))
    }

    private func itemRow(_ item: SearchItem) -> some View {
        Button { app.open(item.route) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.visualState.compactIcon)
                    .font(.syIcon(9))
                    .foregroundStyle(item.visualState.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.syCallout)
                        .foregroundStyle(Color.syText)
                        .lineLimit(2)
                    Text("\(item.repository.nameWithOwner)#\(item.number)")
                        .font(.syCaption.monospaced())
                        .foregroundStyle(Color.syMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 6)
        .help(item.title)
    }
}

struct FirstRunChecklist: View {
    @AppStorage("onboarding.checklistDismissed") private var dismissed = false
    @Environment(\.openSettings) private var openSettings
    @State private var notifications: UNAuthorizationStatus = .notDetermined
    @State private var agents = ClaudeAccountStore.shared
    @State private var jira = JiraConnections.shared

    private var allDone: Bool {
        notifications != .notDetermined && agents.isLoggedIn && jira.isConfigured
    }

    var body: some View {
        if !dismissed, !allDone {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Get set up")
                        .font(.sy(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(Color.syCoralInk)
                    Spacer()
                    Button { dismissed = true } label: { Image(systemName: "xmark").font(.syIcon(9)) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.syMuted)
                        .help("Hide this checklist")
                        .accessibilityLabel("Hide checklist")
                }
                step("Turn on notifications", done: notifications != .notDetermined, detail: "Review requests and agent results, even when PullYard is in the background") {
                    Task {
                        _ = await SystemNotifications.requestAccess()
                        notifications = await SystemNotifications.status()
                    }
                }
                step("Connect Agents", done: agents.isLoggedIn, detail: "Fix review comments and failing checks with an agent") { openSettings() }
                step("Link Jira", done: jira.isConfigured, detail: "Optional · see tickets next to the pull request") { openSettings() }
            }
            .padding(14)
            .frame(width: 420)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color.syRaised))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.syLine))
            .task {
                notifications = await SystemNotifications.status()
                if !agents.isLoggedIn { await agents.refresh() }
            }
        }
    }

    private func step(_ title: String, done: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.syGreen : Color.syDim)
                .font(.syIcon(13, weight: .regular))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.syCallout.weight(.medium)).foregroundStyle(done ? Color.syMuted : Color.syText).strikethrough(done)
                Text(detail).font(.syCaption).foregroundStyle(Color.syMuted)
            }
            Spacer(minLength: 8)
            if !done {
                Button("Set up", action: action).controlSize(.small)
            }
        }
    }
}
