import SwiftUI

struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [NotificationThread] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAll = false
    @State private var selection: String?
    @State private var lastUpdated: Date?
    @State private var loadedKey: String?
    @State private var checkingCache = false
    @State private var rows = RowAppearTracker.shared("notifications")
    @State private var confirmMarkAll = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showAll) {
                Text("Unread").tag(false)
                Text("All").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(Color.syLine).frame(height: 1)
            List(selection: $selection) {
                if let error, !items.isEmpty { ListErrorNote(message: error) { await load() } }
                ForEach(items) { n in
                    NotificationRow(item: n)
                        .rowAppear(n.id, rows)
                        .tag(n.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { if n.route == nil { openExternal(n) } })
                        .contextMenu {
                            if n.unread { Button("Mark as read") { Task { await markRead(n) } } }
                            Button("Done (remove from inbox)") { Task { await markDone(n) } }
                            Button("Open in browser") { openInBrowser(n.webURL) }
                            if let ref = ShortLink.ref(route: n.route) {
                                Button("Copy short link") { app.copyShortLink(ref) }
                            }
                        }
                }
            }
            .overlay {
                if loading && !checkingCache && items.isEmpty {
                    PullYardLoader(size: 44)
                } else if let error, items.isEmpty {
                    ListErrorNote(message: error, centered: true) { await load() }
                } else if items.isEmpty, !loading {
                    ListEmptyNote(
                        title: showAll ? "No notifications" : "All caught up",
                        message: showAll ? "Activity on your repositories shows up here." : "You’ve read everything. New activity shows up here."
                    )
                }
            }
            .onKeyPress(.return) {
                guard let n = selected, n.route == nil else { return .ignored }
                openExternal(n)
                return .handled
            }
            .liveRefresh(updated: lastUpdated, refreshing: loading, error: items.isEmpty ? nil : error) { await load() }
            if items.count >= GitHubAPI.notificationPageSize {
                Text("Showing the latest \(items.count) notifications. Mark some as done to see older ones.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if let n = selected, n.route == nil {
                HStack(spacing: 8) {
                    Image(systemName: "safari").foregroundStyle(Color.syMuted)
                    Text("This notification opens in the browser").font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Open") { openExternal(n) }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(Color.syLine).frame(height: 1) }
            }
        }
        .navigationTitle("Notifications")
        .panelToolbar {
            ToolbarItem {
                Button { confirmMarkAll = true } label: { Label("Mark all read", systemImage: "checkmark.circle") }
                    .help("Mark all as read")
                    .disabled(!items.contains { $0.unread })
            }
        }
        .task(id: "\(showAll)|\(app.cacheAccount ?? "")") { await load() }
        .onChange(of: app.refreshTick) { Task { await load() } }
        .onLiveTick { await load(live: true) }
        .onChange(of: selection) { _, id in
            guard let id, let n = items.first(where: { $0.id == id }) else { return }
            guard let route = n.route else { return }
            app.select(route)
            if n.unread { Task { await markRead(n, quiet: true) } }
        }
        .confirmationDialog("Mark all notifications as read?", isPresented: $confirmMarkAll) {
            Button("Mark All as Read") { Task { await markAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(items.count >= GitHubAPI.notificationPageSize ? "This also marks notifications that aren't loaded in this list." : "Every unread notification in your inbox is marked as read.")
        }
    }

    private var selected: NotificationThread? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    private func openExternal(_ n: NotificationThread) {
        openInBrowser(n.webURL)
        if n.unread { Task { await markRead(n, quiet: true) } }
    }

    private static func cacheKey(_ all: Bool) -> String {
        "notifications|\(all ? "all" : "unread")"
    }

    private func load(live: Bool = false) async {
        guard let api = app.api else { return }
        let all = showAll
        let account = app.cacheAccount
        let key = Self.cacheKey(all)
        let viewKey = "\(account ?? "")|\(key)"
        loading = true
        defer { loading = false }
        async let request = api.notifications(all: all, live: live)
        if loadedKey != viewKey {
            checkingCache = true
            let snap = await ListCache.load([NotificationThread].self, account: account, key: key)
            checkingCache = false
            if let snap, all == showAll, app.api === api {
                rows.ingest(snap.value.map(\.id), mode: .silent)
                loadedKey = viewKey
                items = snap.value
                lastUpdated = snap.saved
            } else if loadedKey?.hasPrefix("\(account ?? "")|") != true {
                items = []
                lastUpdated = nil
            }
        }
        do {
            let fetched = try await request
            guard all == showAll, app.api === api else { return }
            rows.ingest(fetched.map(\.id), mode: loadedKey == viewKey ? .refresh : .cascade)
            loadedKey = viewKey
            items = fetched
            lastUpdated = Date()
            ListCache.save(fetched, account: account, key: key)
            if !showAll { app.unreadCount = items.count }
            error = nil
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }

    private func markRead(_ n: NotificationThread, quiet: Bool = false) async {
        guard let api = app.api else { return }
        do { try await api.markNotificationRead(n.id) } catch {
            if !quiet, !isCancellation(error) { app.showToast("Couldn’t mark as read: \(error.localizedDescription)", isError: true) }
            return
        }
        if let i = items.firstIndex(where: { $0.id == n.id }) { items[i].unread = false }
        app.unreadCount = max(0, app.unreadCount - 1)
        persistChange()
    }

    private func persistChange() {
        let account = app.cacheAccount
        ListCache.save(showAll ? items : items.filter(\.unread), account: account, key: Self.cacheKey(showAll))
        ListCache.remove(account: account, key: Self.cacheKey(!showAll))
    }

    private func markDone(_ n: NotificationThread) async {
        guard let api = app.api else { return }
        do { try await api.markNotificationDone(n.id) } catch {
            if !isCancellation(error) { app.showToast("Couldn’t mark as done: \(error.localizedDescription)", isError: true) }
            return
        }
        items.removeAll { $0.id == n.id }
        if n.unread { app.unreadCount = max(0, app.unreadCount - 1) }
        persistChange()
    }

    private func markAll() async {
        guard let api = app.api else { return }
        do { try await api.markAllNotificationsRead() } catch {
            if !isCancellation(error) { app.showToast("Couldn’t mark all as read: \(error.localizedDescription)", isError: true) }
            return
        }
        for i in items.indices { items[i].unread = false }
        app.unreadCount = 0
        persistChange()
    }
}

struct NotificationRow: View {
    let item: NotificationThread

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(item.unread ? Color.sySky : .clear).frame(width: 7, height: 7).padding(.top, 7).accessibilityLabel("Unread").accessibilityHidden(!item.unread)
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.14)))
                .accessibilityLabel(typeTitle)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subject.title).font(.syBody)
                    .lineLimit(2)
                    .fontWeight(item.unread ? .semibold : .regular)
                    .foregroundStyle(item.unread ? Color.syText : Color.syMuted)
                HStack(spacing: 5) {
                    Avatar(url: item.repository.owner?.avatarUrl, size: 13)
                    Text(item.repository.fullName).lineLimit(1).foregroundStyle(Color.syMuted)
                    Text("·").foregroundStyle(Color.syDim)
                    Text(reason).lineLimit(1).foregroundStyle(reasonColor)
                    Text("·").foregroundStyle(Color.syDim)
                    Text(Fmt.rel(item.updatedAt)).lineLimit(1).foregroundStyle(Color.syDim)
                }
                .font(.syCaption)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch item.subject.type {
        case "PullRequest": return "arrow.triangle.pull"
        case "Issue": return "smallcircle.filled.circle"
        case "Release": return "tag"
        case "Discussion": return "bubble.left.and.bubble.right"
        case "CheckSuite": return "xmark.octagon"
        case "Commit": return "point.3.connected.trianglepath.dotted"
        default: return "bell"
        }
    }

    private var typeTitle: String {
        switch item.subject.type {
        case "PullRequest": return "Pull request"
        case "Issue": return "Issue"
        case "Release": return "Release"
        case "Discussion": return "Discussion"
        case "CheckSuite": return "Check suite"
        case "Commit": return "Commit"
        default: return "Notification"
        }
    }

    private var color: Color {
        switch item.subject.type {
        case "PullRequest": return .syViolet
        case "Issue": return .syGreen
        case "Release": return .syTeal
        case "Discussion": return .syIndigo
        case "CheckSuite": return .syRed
        case "Commit": return .sySky
        default: return .syAmber
        }
    }

    private var reasonColor: Color {
        switch item.reason {
        case "review_requested": return .sySky
        case "mention", "team_mention": return .syAmber
        case "security_alert": return .syRed
        default: return .syMuted
        }
    }

    private var reason: String {
        switch item.reason {
        case "review_requested": return "review requested"
        case "mention": return "mention"
        case "team_mention": return "team mention"
        case "author": return "author"
        case "comment": return "comment"
        case "assign": return "assigned"
        case "state_change": return "state change"
        case "subscribed": return "subscribed"
        case "ci_activity": return "CI"
        case "manual": return "subscribed"
        case "security_alert": return "security alert"
        default: return item.reason
        }
    }
}
