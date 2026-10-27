import SwiftUI
import UserNotifications

struct NotificationSettingsSection: View {
    @State private var tick = 0
    @State private var status: UNAuthorizationStatus = .notDetermined
    @AppStorage(DockBadge.enabledKey) private var dockBadge = true
    @AppStorage(DockBadge.agentsKey) private var dockAgents = true

    var body: some View {
        Section {
            switch status {
            case .denied:
                HStack {
                    Label("Notifications are turned off for PullYard", systemImage: "bell.slash")
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Open System Settings…") { SystemNotifications.openSystemSettings() }
                }
            case .notDetermined:
                HStack {
                    Text("PullYard asks for permission the first time it has something to tell you.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Allow…") { Task { await requestAccess() } }
                }
            default:
                EmptyView()
            }
            ForEach(NotifyKind.allCases) { kind in
                Toggle(kind.title, isOn: Binding(get: { _ = tick; return kind.enabled }, set: { on in
                    kind.setEnabled(on)
                    tick += 1
                    if on { Task { await requestAccess() } }
                }))
            }
            Text("Pull request alerts compare each refresh with the previous one, so nothing fires for what was already waiting when PullYard opened or switched accounts. Agent alerts only appear when you aren't looking at that session.")
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
            Toggle("Show badge on Dock icon", isOn: $dockBadge)
                .onChange(of: dockBadge) { DockBadge.apply() }
            Toggle("Count agents waiting for you", isOn: $dockAgents)
                .disabled(!dockBadge)
                .onChange(of: dockAgents) { DockBadge.apply() }
        } header: {
            SettingsHeader(title: "Notifications", icon: "bell.badge.fill", color: .syAmber)
        }
        .task { status = await SystemNotifications.status() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await SystemNotifications.status() }
        }
    }

    private func requestAccess() async {
        if status == .notDetermined { _ = await SystemNotifications.requestAccess() }
        status = await SystemNotifications.status()
    }
}
