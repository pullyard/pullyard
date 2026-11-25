import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mobile.refresh.minutes") private var refreshMinutes = 5
    @AppStorage("mobile.inbox.markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(ThemeStore.styleKey) private var styleRaw = ThemeStyle.pullyard.rawValue
    @AppStorage(ThemeStore.appearanceKey) private var appearanceRaw = AppearanceMode.automatic.rawValue
    @AppStorage(NotifyPrefs.enabled) private var notifyEnabled = false
    @AppStorage(NotifyPrefs.reviews) private var notifyReviews = true
    @AppStorage(NotifyPrefs.mentions) private var notifyMentions = true
    @AppStorage(NotifyPrefs.myReviews) private var notifyMyReviews = true
    @AppStorage(NotifyPrefs.ci) private var notifyCI = true
    @AppStorage(NotifyPrefs.badge) private var notifyBadge = false
    @AppStorage("mobile.pulls.groupByProject") private var groupByProject = true
    @AppStorage("mobile.merge.method") private var mergeMethod = MergeMethod.squash.rawValue
    @AppStorage("mobile.merge.deleteBranch") private var deleteBranch = true
    @AppStorage("mobile.diff.wrap") private var diffWrap = true
    @State private var notificationsDenied = false
    @State private var showTour = false
    @State private var confirmSignOut = false

    var body: some View {
        List {
            if let user = model.user {
                Section("Account") {
                    HStack(spacing: 12) {
                        AvatarView(url: user.avatarUrl, size: 48, fallback: user.login)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.name ?? user.login).mobileFont(size: 17, weight: .semibold).foregroundStyle(MobileTheme.ink)
                            Text("@\(user.login) · GitHub").mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                        }
                        Spacer()
                        if let url = user.htmlUrl { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.accessibilityLabel("Open your GitHub profile") }
                    }.padding(.vertical, 4)
                }
                .pyRow()
            }

            MacLinkSection()

            Section {
                HStack(spacing: 12) {
                    ForEach(ThemeStyle.allCases) { option in
                        ThemeOptionCard(style: option, selected: styleRaw == option.rawValue) {
                            withAnimation(.snappy) { styleRaw = option.rawValue }
                        }
                    }
                }
                .padding(.vertical, 6)
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("PullYard uses the brand palette from the desktop app. System follows standard iOS colors.")
            }
            .pyRow()

            Section {
                Toggle(isOn: $notifyEnabled) { Label("Notifications", systemImage: "bell.badge") }
                    .onChange(of: notifyEnabled) { _, on in if on { Task { await requestNotifications() } } else { BackgroundSync.schedule() } }
                if notifyEnabled {
                    Toggle("Review requests", isOn: $notifyReviews)
                    Toggle("Mentions", isOn: $notifyMentions)
                    Toggle("Reviews on my pull requests", isOn: $notifyMyReviews)
                    Toggle("Failed checks on my pull requests", isOn: $notifyCI)
                }
                Toggle(isOn: $notifyBadge) { Label("Unread count on app icon", systemImage: "app.badge") }
                    .onChange(of: notifyBadge) { _, on in
                        if on { Task { await requestNotifications() } }
                        Task { await BackgroundSync.updateBadge(unread: model.unreadCount) }
                        BackgroundSync.schedule()
                    }
                if notificationsDenied {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                        Label("Notifications are off for PullYard. Open iOS Settings", systemImage: "exclamationmark.triangle")
                    }
                    .foregroundStyle(MobileTheme.amberInk)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("PullYard has no server, so it checks GitHub in the background on this iPhone. iOS decides when that happens — usually every 15 minutes to a few hours, more often for apps you open regularly.")
            }
            .pyRow()

            Section {
                Toggle("Group pull requests by project", isOn: $groupByProject)
                Picker("Default merge method", selection: $mergeMethod) {
                    ForEach(MergeMethod.allCases) { Text($0.short).tag($0.rawValue) }
                }
                Toggle("Delete branch after merge", isOn: $deleteBranch)
                Toggle("Wrap long lines in diffs", isOn: $diffWrap)
                NavigationLink { TemplatesManagerView() } label: { Label("Reply templates", systemImage: "text.badge.plus") }
            } header: {
                Text("Pull requests")
            }
            .pyRow()

            Section {
                Picker("Auto-refresh", selection: $refreshMinutes) {
                    Text("Every minute").tag(1)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Manual only").tag(0)
                }
                Toggle("Mark notifications read when opened", isOn: $markReadOnOpen)
            } header: {
                Text("Refresh & Inbox")
            } footer: {
                Text("Auto-refresh runs only while PullYard is open. Pull down on any list to refresh right away.")
            }
            .pyRow()

            Section {
                if model.scopes.isEmpty {
                    Label("GitHub didn't report token scopes", systemImage: "info.circle").foregroundStyle(MobileTheme.amberInk)
                } else {
                    ForEach(["repo", "notifications"], id: \.self) { required in
                        let present = model.scopes.contains(required)
                        Label(required, systemImage: present ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(present ? MobileTheme.green : MobileTheme.coral)
                            .accessibilityLabel("\(required): \(present ? "granted" : "not granted")")
                    }
                }
            } header: {
                Text("Token access")
            } footer: {
                Text("The Inbox needs a classic token with the notifications scope; pull requests and reviews need repo. Fine-grained tokens can't read GitHub notifications.")
            }
            .pyRow()

            Section {
                Button(role: .destructive) { confirmSignOut = true } label: { Label("Sign out of GitHub", systemImage: "rectangle.portrait.and.arrow.right") }
            }
            .pyRow()

            Section("About") {
                LabeledContent("PullYard for iPhone", value: Self.version)
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: { Label("Language", systemImage: "globe") }
                Button { showTour = true } label: { Label("Welcome tour", systemImage: "sailboat") }
                Link(destination: URL(string: "https://pullyard.app/changelog.html")!) { Label("What's new", systemImage: "sparkles") }
                Link(destination: URL(string: "https://pullyard.app/roadmap.html")!) { Label("Roadmap", systemImage: "map") }
                Link(destination: URL(string: "https://github.com/pullyard/pullyard/issues/new")!) { Label("Send feedback", systemImage: "envelope") }
                Link(destination: URL(string: "https://github.com/pullyard/pullyard")!) { Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Label("No server, no analytics", systemImage: "hand.raised")
                Text("GitHub is a trademark of GitHub, Inc. PullYard is an independent project.").mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            .pyRow()
        }
        .scrollContentBackground(.hidden)
        .background(BrandBackdrop())
        .navigationTitle("Settings")
        .fullScreenCover(isPresented: $showTour) { OnboardingView { showTour = false } }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out and clear local data", role: .destructive) { model.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your GitHub token, cached pull requests and saved drafts will be removed from this iPhone.") }
    }

    private func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        notificationsDenied = !granted
        if !granted { notifyEnabled = false; notifyBadge = false }
        BackgroundSync.schedule()
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }
}

private struct ThemeOptionCard: View {
    let style: ThemeStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview
                    .frame(height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(selected ? MobileTheme.accent : MobileTheme.line, lineWidth: selected ? 2.5 : 1))
                HStack(spacing: 5) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? MobileTheme.accent : MobileTheme.muted)
                    Text(style.rawValue).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pyPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(style.rawValue) theme")
    }

    @ViewBuilder private var preview: some View {
        if style == .pullyard {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(uiColor: UIColor(hex: 0x1A2540)), MobileTheme.navy], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 0.42, green: 0.33, blue: 0.84).opacity(0.6)).frame(width: 70).blur(radius: 22).offset(x: -10, y: -40)
                Circle().fill(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.5)).frame(width: 60).blur(radius: 20).offset(x: 70, y: -30)
                PullYardLogoMark(progress: 1, size: 54).padding(10)
            }
        } else {
            ZStack(alignment: .bottomLeading) {
                Color(uiColor: .systemGroupedBackground)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .systemBlue)).frame(width: 46, height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .secondaryLabel)).frame(width: 70, height: 5)
                    RoundedRectangle(cornerRadius: 3).fill(Color(uiColor: .tertiaryLabel)).frame(width: 54, height: 5)
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
        }
    }
}
