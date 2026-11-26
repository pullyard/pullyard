import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(SplitAppShell.flagKey) private var nativeSplit = false
    @AppStorage("pollInterval") private var pollInterval = 30.0
    @AppStorage("oauthClientID") private var clientID = ""
    @AppStorage(Theme.styleKey) private var themeStyle = ThemeStyle.pullyard.rawValue
    @AppStorage(Theme.appearanceKey) private var appearance = AppearanceMode.auto.rawValue
    @State private var browserTick = 0
    @State private var confirmClaudeLogout = false
    @State private var loggingOut = false
    @State private var showAddProfile = false
    @State private var showAddAccount = false
    @State private var pendingSwitch: GitAccount?
    @State private var confirmSignOut = false
    @State private var showLicenses = false
    @State private var tokenStatus: String?
    @State private var tokenFailed = false
    @State private var refreshingToken = false
    @AppStorage("clipboard.watch") private var watchClipboard = true
    @AppStorage(ListDensity.key) private var density: ListDensity = .roomy
    @AppStorage("settings.tab") private var tab = "general"
    @AppStorage(SessionCost.budgetKey) private var sessionBudget = 0.0
    @AppStorage(Updater.autoCheckKey) private var autoCheckUpdates = true
    @AppStorage(Updater.devChannelKey) private var devUpdates = false
    @AppStorage(Diagnostics.enabledKey) private var diagnosticsEnabled = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView(selection: $tab) {
            generalForm
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            accountsForm
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag("accounts")
            AgentSettingsForm()
                .tabItem { Label("Agents", systemImage: "terminal") }
                .tag("agents")
            integrationsForm
                .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
                .tag("integrations")
            PYLinkSettingsView()
                .tabItem { Label("iPhone", systemImage: "iphone") }
                .tag("iphone")
            advancedForm
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag("advanced")
        }
        .tint(Color.syAccentFill)
        .task { await ClaudeAccountStore.shared.refresh() }
        .sheet(isPresented: $showAddProfile) { AddClaudeProfileSheet().environment(app) }
        .sheet(isPresented: $showLicenses) { LicensesSheet() }
        .modifier(AccountDialogs(pendingSwitch: $pendingSwitch, confirmSignOut: $confirmSignOut, showAdd: $showAddAccount))
        .confirmationDialog("Sign out of Claude Code?", isPresented: $confirmClaudeLogout) {
            Button("Sign Out", role: .destructive) {
                loggingOut = true
                Task {
                    app.claude.sleepAll()
                    await ClaudeAccountStore.shared.logout()
                    loggingOut = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This also signs out Claude Code in Terminal. Open sessions will go to sleep. You can sign in again (including with another account) here or in the Agents section.")
        }
        .frame(width: 560, height: 580)
    }

    private var generalForm: some View {
        Form {
            Section {
                Picker("Theme", selection: $themeStyle) {
                    ForEach(ThemeStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Mode", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: Binding(get: { Double(TextZoom.shared.scale) }, set: { TextZoom.shared.setScale(CGFloat($0)) })) {
                    ForEach(TextZoom.levels, id: \.self) { level in
                        Text(abs(level - 1) < 0.001 ? "100% (default)" : "\(Int((level * 100).rounded()))%").tag(Double(level))
                    }
                }
                .help("Also ⌘+ and ⌘− in the main window")
                Picker("List density", selection: $density) {
                    ForEach(ListDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("How much each pull request row shows")
                Toggle("Show PullYard in the menu bar", isOn: Binding(get: { app.showMenuBar }, set: { app.showMenuBar = $0 }))
            } header: {
                SettingsHeader(title: "Appearance", icon: "paintpalette.fill", color: .syViolet)
            }
            Section {
                Picker("Open links in", selection: Binding(get: { LinkBrowser.selected }, set: { LinkBrowser.selected = $0; browserTick += 1 })) {
                    Text("System default").tag(LinkBrowser.systemDefault)
                    ForEach(LinkBrowser.installed) { Text($0.name).tag($0.id) }
                }
                .id(browserTick)
                Toggle("Offer to open a copied pull request or issue link", isOn: $watchClipboard)
                    .onChange(of: watchClipboard) { app.checkClipboard() }
            } header: {
                SettingsHeader(title: "Links", icon: "link", color: .syIndigo)
            }
            Section {
                Picker("Auto-refresh lists", selection: $pollInterval) {
                    Text("Every 15 seconds").tag(15.0)
                    Text("Every 30 seconds").tag(30.0)
                    Text("Every minute").tag(60.0)
                    Text("Every 2 minutes").tag(120.0)
                    Text("Every 5 minutes").tag(300.0)
                    Text("Every 15 minutes").tag(900.0)
                }
                .onChange(of: pollInterval) { app.startPolling() }
            } header: {
                SettingsHeader(title: "Refresh", icon: "arrow.clockwise", color: .syGreen)
            }
            NotificationSettingsSection()
            Section {
                Toggle("Check for updates automatically", isOn: $autoCheckUpdates)
                Toggle(isOn: $devUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dev updates")
                        Text("For developers: every push to the dev branch is built on GitHub, downloaded in the background and announced with a notification. Dev builds can be unstable.")
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                    }
                }
                .onChange(of: devUpdates) { _, _ in
                    Task { await Updater.shared.check(userInitiated: false) }
                }
                HStack {
                    Text("Current version \(Updater.shared.currentDisplayVersion)")
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Check Now") {
                        openWindow(id: "update")
                        Task { await Updater.shared.check(userInitiated: true) }
                    }
                    .disabled(Updater.shared.isBusy)
                }
            } header: {
                SettingsHeader(title: "Updates", icon: "arrow.down.circle", color: .syGreen)
            }
        }
        .formStyle(.grouped)
        .surface(.panel)
    }

    private var accountsForm: some View {
        Form {
            Section {
                if let u = app.user {
                    HStack(spacing: 10) {
                        Avatar(url: u.avatarUrl, size: 36)
                        VStack(alignment: .leading) {
                            Text(u.name ?? u.login).font(.syHeadline).foregroundStyle(Color.syText)
                            Text(app.accountSubtitle ?? "").foregroundStyle(Color.syMuted)
                        }
                        Spacer()
                        Text(app.provider.title).font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                    }
                    if let account = app.account {
                        AccountLockSettings(account: account).environment(app)
                    }
                    if app.provider.isGitHub {
                        LabeledContent("Token scopes", value: app.scopes.isEmpty ? "fine-grained / unknown" : app.scopes.joined(separator: ", "))
                    }
                    HStack {
                        Menu("Switch Account") {
                            AccountMenuItems(pendingSwitch: $pendingSwitch, confirmSignOut: $confirmSignOut, showAdd: $showAddAccount)
                        }
                        .fixedSize()
                        if app.provider.isGitHub, GHCLI.binary != nil {
                            Button(refreshingToken ? "Refreshing…" : "Refresh token from gh") {
                                refreshingToken = true
                                tokenStatus = nil
                                Task {
                                    let failure = await app.refreshTokenFromGH()
                                    refreshingToken = false
                                    tokenFailed = failure != nil
                                    tokenStatus = failure.map { "Couldn’t read the token from gh: \($0)" } ?? "Token refreshed from gh."
                                }
                            }
                            .disabled(refreshingToken)
                        }
                        Spacer()
                        if app.canLock {
                            Button("Lock Now") { app.lockNow() }
                        }
                        Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                    }
                    if let tokenStatus {
                        Label(tokenStatus, systemImage: tokenFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.syCaption)
                            .foregroundStyle(tokenFailed ? Color.syRed : Color.syMuted)
                    }
                } else {
                    Text("Not signed in").foregroundStyle(Color.syMuted)
                }
            } header: {
                SettingsHeader(title: "Account", icon: "person.fill", color: .syTeal)
            }
            if app.phase == .loggedIn {
                Section {
                    HStack {
                        Picker("Account", selection: Binding(get: { ClaudeProfiles.shared.activeID }, set: { app.switchClaudeProfile(to: $0) })) {
                            ForEach(ClaudeProfiles.shared.visible) { p in
                                Text(p.label + (p.email.map { " — \($0)" } ?? "")).tag(p.id)
                            }
                        }
                        Button("Add…") { showAddProfile = true }
                    }
                    switch ClaudeAccountStore.shared.status {
                    case .loggedIn(let info):
                        ClaudeAccountCard(info: info, compact: true)
                        HStack {
                            Button("Sign out of Claude Code", role: .destructive) { confirmClaudeLogout = true }
                            Spacer()
                            if loggingOut { PYLoader(size: 16) }
                        }
                        .disabled(loggingOut)
                    case .notInstalled:
                        Text("claude CLI isn't installed").foregroundStyle(Color.syMuted)
                    default:
                        HStack {
                            Text("Not signed in to Claude").foregroundStyle(Color.syMuted)
                            Spacer()
                            Button("Sign in…") {
                                app.section = .claude
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        }
                    }
                    Text("Model, permission mode and sleep settings are in the Agents tab.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Picker("Pause a session at", selection: $sessionBudget) {
                        ForEach(SessionCost.choices, id: \.self) { v in
                            Text(v == 0 ? "No limit" : SessionCost.format(v)).tag(v)
                        }
                    }
                    Text("When an agent session's reported cost reaches the limit, new messages wait until you continue. Useful with API keys, OpenRouter or another endpoint; with a Claude plan the cost is an estimate.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                } header: {
                    SettingsHeader(title: "Agents", icon: "terminal.fill", color: .syCoral)
                }
            }
        }
        .formStyle(.grouped)
        .surface(.panel)
    }

    private var integrationsForm: some View {
        Form {
            Section {
                JiraConnectForm()
            } header: {
                SettingsHeader(title: "Jira", icon: "ticket", color: .sySky)
            }
            Section {
                JiraAttachmentCacheSection()
            } header: {
                SettingsHeader(title: "Jira attachments", icon: "paperclip", color: .syViolet)
            }
        }
        .formStyle(.grouped)
        .surface(.panel)
    }

    private var advancedForm: some View {
        Form {
            Section {
                Toggle("Record network diagnostics", isOn: $diagnosticsEnabled)
                    .onChange(of: diagnosticsEnabled) { Diagnostics.shared.setEnabled(diagnosticsEnabled) }
                HStack {
                    Text("Keeps the last 1000 API requests in memory: timing, size, status and rate limit. No tokens or request bodies.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Open Diagnostics") { openWindow(id: "diagnostics") }
                }
            } header: {
                SettingsHeader(title: "Diagnostics", icon: "gauge.with.dots.needle.33percent", color: .sySky)
            }
            Section {
                Toggle("Native split view", isOn: $nativeSplit)
                Text("Uses the macOS split view for the sidebar, list and detail. On macOS 26 the sidebar becomes glass. The narrow icon rail is not available in this mode. Experimental.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            } header: {
                SettingsHeader(title: "Window layout", icon: "sidebar.left", color: .syViolet)
            }
            Section {
                TextField("Client ID", text: $clientID)
            } header: {
                SettingsHeader(title: "GitHub OAuth app (advanced)", icon: "key.fill", color: .syAmber)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buy me a pizza 🍕").foregroundStyle(Color.syText)
                        Text("Pay what you want, from $3. PullYard stays free and open source.")
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                    }
                    Spacer()
                    Button("Support…") { openInBrowser(Support.pizzaURL) }
                }
            } header: {
                SettingsHeader(title: "Support PullYard", icon: "heart.fill", color: .syCoral)
            }
            Section {
                HStack(spacing: 14) {
                    DrawnLogoMark(key: "settings-about", size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PullYard")
                            .font(.system(size: TextZoom.shared.size(22), weight: .semibold, design: .serif))
                            .foregroundStyle(Color.syText)
                        Text("Version \(Updater.shared.currentVersion)")
                            .font(.syCaption.monospacedDigit())
                            .foregroundStyle(Color.syMuted)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                Text(Legal.disclaimer)
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                HStack {
                    Text("PullYard is open source under the MIT License.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Third-Party Licenses…") { showLicenses = true }
                }
            } header: {
                SettingsHeader(title: "About", icon: "info.circle.fill", color: .syMuted)
            }
        }
        .formStyle(.grouped)
        .surface(.panel)
    }
}

struct AgentSettingsForm: View {
    @State private var confirmReset = false
    private var defaults: AgentDefaults { AgentDefaults.shared }

    var body: some View {
        @Bindable var d = AgentDefaults.shared
        Form {
            Section {
                Picker("Open new sessions as", selection: $d.kind) {
                    Text("Chat").tag(ClaudeTabKind.chat)
                    Text("Terminal").tag(ClaudeTabKind.terminal)
                }
                .pickerStyle(.segmented)
                Picker("Model", selection: $d.model) {
                    Text("Default").tag("")
                    ForEach(d.modelChoices) { m in
                        Text(m.description.isEmpty ? m.displayName : "\(m.displayName) — \(m.description)").tag(m.value)
                    }
                }
                Picker("Effort", selection: $d.effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.title).tag($0) }
                }
                Picker("Permission mode", selection: $d.mode) {
                    ForEach(ClaudeMode.allCases) { Text($0.title).tag($0) }
                }
                Text(d.mode.detail)
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                if d.knownModels.isEmpty {
                    Text("Open a chat once to load the full model list from Claude Code.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                }
            } header: {
                SettingsHeader(title: "New sessions", icon: "sparkles", color: .syViolet)
            } footer: {
                Text("Used for every new chat and terminal session. You can still change them per chat from the composer.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            Section {
                Toggle("Remember changes made in the chat composer", isOn: $d.rememberComposerChoice)
                Text("When on, picking a model, effort or mode in a chat also makes it the default for the next chats.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            } header: {
                SettingsHeader(title: "Composer", icon: "text.cursor", color: .syIndigo)
            }
            Section {
                Picker("Sleep idle sessions after", selection: $d.idleMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                Text("A sleeping session uses no memory: the claude process stops, the conversation stays, and the next message resumes it.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                Toggle("Reopen sessions from last time", isOn: $d.restoreTabs)
                Toggle("Warn before quitting while agents are working", isOn: $d.confirmQuit)
            } header: {
                SettingsHeader(title: "Running sessions", icon: "moon.zzz.fill", color: .syTeal)
            }
            Section {
                ForEach(PromptLibrary.shared.prompts) { prompt in
                    SavedPromptRow(prompt: prompt)
                }
                if PromptLibrary.shared.prompts.isEmpty {
                    Text("Save a prompt from the bookmark menu in the chat composer, or add one here.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                }
                Button("Add Prompt") { PromptLibrary.shared.add(text: "Describe what the agent should do", title: "New prompt") }
            } header: {
                SettingsHeader(title: "Saved prompts", icon: "bookmark.fill", color: .syCoral)
            }
            Section {
                usageRow("Today", days: 1)
                usageRow("Last 7 days", days: 7)
                usageRow("Last 30 days", days: 30)
                HStack {
                    Text("API-equivalent cost reported by Claude Code for chats run in PullYard on this Mac. With a subscription this is not what you are billed.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Clear") { AgentUsageLedger.shared.clear() }
                        .disabled(AgentUsageLedger.shared.days.isEmpty)
                }
            } header: {
                SettingsHeader(title: "Usage", icon: "chart.bar.fill", color: .syAmber)
            }
            Section {
                HStack {
                    Text("Restore the default model, effort, mode and sleep settings.")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Reset…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .surface(.panel)
        .confirmationDialog("Reset agent settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { defaults.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open sessions keep their current settings.")
        }
    }

    private func usageRow(_ title: String, days: Int) -> some View {
        let total = AgentUsageLedger.shared.total(lastDays: days)
        return LabeledContent(title) {
            Text(total.turns == 0 ? "—" : String(format: "$%.2f · %d turn%@", total.cost, total.turns, total.turns == 1 ? "" : "s"))
                .monospacedDigit()
                .foregroundStyle(Color.syMuted)
        }
    }
}

struct SettingsHeader: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            IconTile(systemImage: icon, color: color, size: 16)
            Text(title).font(.syBody.weight(.semibold)).foregroundStyle(Color.syText)
        }
    }
}

enum Legal {
    static let disclaimer = "PullYard is an independent project and is not affiliated with or endorsed by GitHub, Inc., Anthropic, PBC or Atlassian. GitHub, Claude, Claude Code and Jira are trademarks of their respective owners."
    static let noticesURL = "https://github.com/pullyard/pullyard/blob/main/Resources/THIRD-PARTY-NOTICES.txt"

    static var notices: String? {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Third-Party Licenses").font(.syHeadline).foregroundStyle(Color.syText)
            ScrollView {
                Text(Legal.notices ?? "Licenses are bundled with the app. See \(Legal.noticesURL)")
                    .font(.syCaption.monospaced())
                    .foregroundStyle(Color.syText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .card(radius: 8, fill: .sySunken)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .surface(.panel)
    }
}

struct SavedPromptRow: View {
    let prompt: SavedPrompt
    @State private var title = ""
    @State private var text = ""
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            TextField("Title", text: $title)
                .onSubmit(save)
            TextEditor(text: $text)
                .font(.syBody)
                .frame(minHeight: 70, maxHeight: 160)
                .scrollContentBackground(.hidden)
            HStack {
                Button("Delete", role: .destructive) { PromptLibrary.shared.remove(prompt.id) }
                Spacer()
                Button("Save", action: save)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (title == prompt.title && text == prompt.text))
            }
        } label: {
            Text(prompt.title).lineLimit(1)
        }
        .onAppear {
            title = prompt.title
            text = prompt.text
        }
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        PromptLibrary.shared.update(SavedPrompt(id: prompt.id, title: name.isEmpty ? PromptLibrary.title(for: body) : name, text: body))
    }
}
