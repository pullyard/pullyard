import SwiftUI

struct LoginView: View {
    var embedded = false
    var onDone: (() -> Void)?
    @Environment(AppModel.self) private var app
    @AppStorage("loginProvider") private var providerRaw = GitProvider.github.rawValue
    @State private var host = ""
    @State private var email = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var busy = false
    @State private var error: String?
    @State private var device: DeviceCode?
    @State private var deviceTask: Task<Void, Never>?
    @State private var showDevice = false
    @State private var prefilled: GitAccount?
    @State private var deviceUsesBundled = false

    private var provider: GitProvider { GitProvider(rawValue: providerRaw) ?? .github }

    private var effectiveHost: String {
        provider.hostEditable ? GitProvider.normalizeHost(host) : provider.defaultHost
    }

    private var clientIDKey: String {
        provider == .github ? "oauthClientID" : "oauthClientID.\(provider.rawValue)"
    }

    private var pace: Double { GitAccounts.shared.accounts.isEmpty ? 1 : 0.5 }

    private var supportsDevice: Bool { provider.isGitHub || provider == .gitlab }

    static var bundledGitHubClientID: String? {
        let id = (Bundle.main.object(forInfoDictionaryKey: "PYGitHubOAuthClientID") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    private var oneClick: Bool { provider == .github && Self.bundledGitHubClientID != nil }

    private var cliBinary: String? {
        switch provider {
        case .github, .githubEnterprise: return GHCLI.binary
        case .gitlab: return GLabCLI.binary
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if !embedded {
                    WelcomeHero(pace: pace)
                    WelcomeFeatures(pace: pace)
                        .padding(.bottom, 4)
                    savedAccounts
                        .welcomeStage(1.85 * pace, enabled: !embedded)
                }

                VStack(spacing: 18) {
                    Picker("Service", selection: $providerRaw) {
                        ForEach(GitProvider.allCases) { Text($0.shortTitle).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if provider.hostEditable {
                        card {
                            cardTitle("\(provider.title) server", icon: "server.rack", color: .syTeal)
                            TextField(provider.hostPlaceholder, text: $host)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    if oneClick {
                        card {
                            cardTitle("Sign in with GitHub", icon: "globe", color: .syIndigo)
                            Text("Opens github.com in your browser. Enter the code shown here and you're in — no token to copy.")
                                .font(.syCallout).foregroundStyle(Color.syMuted)
                            if let device, deviceUsesBundled {
                                deviceCodeRow(device)
                            } else {
                                Button {
                                    startDevice(clientOverride: Self.bundledGitHubClientID)
                                } label: {
                                    Label("Sign in with GitHub", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                        }
                    }

                    if let _ = cliBinary {
                        card {
                            cardTitle(provider == .gitlab ? "GitLab CLI" : "GitHub CLI", icon: "terminal.fill", color: .sySky)
                            Text(provider == .gitlab ? "Use the token you're signed in with in `glab`." : "Use the token you're signed in with in `gh`.").font(.syCallout).foregroundStyle(Color.syMuted)
                            Button {
                                signInWithCLI()
                            } label: {
                                Label(provider == .gitlab ? "Sign in with glab" : "Sign in with gh", systemImage: "terminal").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(effectiveHost.isEmpty)
                        }
                    }

                    card {
                        cardTitle(provider == .bitbucket ? "API token" : "Personal Access Token", icon: "key.fill", color: .syAmber)
                        Text(provider.tokenHint).font(.syCallout).foregroundStyle(Color.syMuted)
                        if provider == .bitbucket {
                            TextField("Atlassian account email", text: $email)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.username)
                        }
                        HStack {
                            SecureField(provider.tokenPlaceholder, text: $token)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(loginWithToken)
                            Button("Sign in", action: loginWithToken)
                                .buttonStyle(.borderedProminent)
                                .disabled(!canSubmitToken)
                        }
                        if let url = provider.tokenCreateURL(host: effectiveHost) {
                            Button(provider == .bitbucket ? "Create an API token at id.atlassian.com" : "Create a token on \(effectiveHost)") {
                                openInBrowser(url)
                            }
                            .buttonStyle(.link)
                        }
                    }

                    if supportsDevice {
                        card {
                            DisclosureGroup(isExpanded: $showDevice) {
                                deviceContent.padding(.top, 6)
                            } label: {
                                cardTitle(oneClick ? "Use your own OAuth App" : "Sign in via browser (OAuth Device Flow)", icon: oneClick ? "gearshape" : "globe", color: .syIndigo)
                            }
                        }
                    }

                    if embedded {
                        Label("Adding an account switches to it. A new account gets its own Agents sign-in; the first account keeps the one you already use.", systemImage: "info.circle")
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if busy { ProgressView().controlSize(.small) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.syRed)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .card(radius: 10, fill: Color.syRed.opacity(0.08))
                    }
                }
                .welcomeStage(1.95 * pace, enabled: !embedded)
            }
            .padding(embedded ? 20 : 40)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background { if !embedded { WelcomeBackdrop() } }
        .onAppear(perform: providerChanged)
        .onChange(of: providerRaw) { providerChanged() }
        .onChange(of: clientID) { UserDefaults.standard.set(clientID, forKey: clientIDKey) }
        .onDisappear { deviceTask?.cancel() }
    }

    @ViewBuilder
    private var savedAccounts: some View {
        let accounts = GitAccounts.shared.accounts
        if !accounts.isEmpty {
            card {
                cardTitle("Your accounts", icon: "person.2.fill", color: .syGreen)
                ForEach(accounts) { a in
                    HStack(spacing: 10) {
                        Avatar(url: a.avatarUrl, size: 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(a.name ?? a.login).font(.syCallout.weight(.medium)).foregroundStyle(Color.syText)
                            Text("\(a.provider.title) · \(a.subtitle)").font(.syCaption).foregroundStyle(Color.syMuted)
                        }
                        Spacer()
                        if GitAccounts.shared.hasCredential(a) {
                            Button("Continue") { app.requestSwitch(to: a.id) }
                        } else {
                            Button("Sign in again") { prefill(a) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deviceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(deviceHelp).font(.syCallout).foregroundStyle(Color.syMuted)
            TextField(provider == .gitlab ? "Application ID" : "Client ID", text: $clientID).textFieldStyle(.roundedBorder)
            if let device, !deviceUsesBundled {
                deviceCodeRow(device)
            } else {
                Button("Get code") { startDevice() }
                    .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || effectiveHost.isEmpty)
            }
        }
    }

    private func deviceCodeRow(_ device: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(device.userCode)
                    .font(.syTitle.monospaced().weight(.bold))
                    .foregroundStyle(Color.syText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .card(radius: 8, fill: .sySunken)
                Button("Copy and open") {
                    copyToPasteboard(device.userCode)
                    openInBrowser(device.verificationUri)
                }
                .buttonStyle(.borderedProminent)
                WakeLoader()
                Spacer(minLength: 0)
                Button("Cancel") {
                    deviceTask?.cancel()
                    self.device = nil
                }
                .buttonStyle(.link)
            }
            Text("The code is copied. Paste it at \(device.verificationUri) — you'll be signed in automatically.").font(.syCaption).foregroundStyle(Color.syMuted)
        }
    }

    private var deviceHelp: String {
        switch provider {
        case .gitlab:
            return "Requires GitLab 17.1 or later and the Application ID of your own OAuth application (User settings → Applications): not confidential, scope api, “Device authorization grant” enabled."
        default:
            return "Requires the Client ID of your own OAuth App (Settings → Developer settings → OAuth Apps, enable “Enable Device Flow”)."
        }
    }

    private var canSubmitToken: Bool {
        let hasToken = !token.trimmingCharacters(in: .whitespaces).isEmpty
        let hasEmail = provider != .bitbucket || !email.trimmingCharacters(in: .whitespaces).isEmpty
        return hasToken && hasEmail && !effectiveHost.isEmpty
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 12)
    }

    private func cardTitle(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            IconTile(systemImage: icon, color: color, size: 22)
            Text(title).font(.syHeadline).foregroundStyle(Color.syText)
        }
    }

    private func providerChanged() {
        host = provider.defaultHost
        if let a = prefilled, a.provider == provider {
            host = a.host
            email = a.email ?? ""
        }
        prefilled = nil
        token = ""
        error = nil
        deviceTask?.cancel()
        device = nil
        clientID = UserDefaults.standard.string(forKey: clientIDKey) ?? ""
    }

    private func prefill(_ a: GitAccount) {
        prefilled = a
        if providerRaw == a.provider.rawValue {
            providerChanged()
        } else {
            providerRaw = a.provider.rawValue
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func finish(_ credential: GitCredential) async throws {
        try await app.addAccount(provider, host: effectiveHost, credential: credential, email: provider == .bitbucket ? email : nil)
        onDone?()
    }

    private func signInWithCLI() {
        let host = effectiveHost
        let provider = provider
        run {
            let t = provider == .gitlab ? try await GLabCLI.token(host: host) : try await GHCLI.token(host: host)
            try await finish(GitCredential(token: t))
        }
    }

    private func loginWithToken() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitToken else { return }
        run { try await finish(GitCredential(token: t)) }
    }

    private func startDevice(clientOverride: String? = nil) {
        let id = clientOverride ?? clientID.trimmingCharacters(in: .whitespaces)
        deviceUsesBundled = clientOverride != nil
        let endpoint = provider == .gitlab ? DeviceFlow.gitlab(host: effectiveHost) : DeviceFlow.github(host: effectiveHost)
        let keepRefresh = provider == .gitlab
        error = nil
        deviceTask?.cancel()
        deviceTask = Task {
            do {
                let code = try await DeviceFlow.start(clientID: id, endpoint: endpoint)
                device = code
                copyToPasteboard(code.userCode)
                openInBrowser(code.verificationUri)
                let token = try await DeviceFlow.poll(clientID: id, code: code, endpoint: endpoint)
                var credential = keepRefresh ? token.credential : GitCredential(token: token.accessToken)
                if keepRefresh { credential.clientID = id }
                try await finish(credential)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            device = nil
        }
    }
}

private struct WelcomeHero: View {
    let pace: Double

    var body: some View {
        VStack(spacing: 10) {
            LogoDrawOn(size: 210, duration: 1.7)
                .shadow(color: Color.syViolet.opacity(0.18), radius: 28, y: 10)
                .padding(.bottom, 4)
            Text("PullYard")
                .font(.sy(size: 36, weight: .bold))
                .foregroundStyle(Color.syText)
                .welcomeStage(1.15 * pace)
            Text("Pull requests, without the browser")
                .font(.syTitle3)
                .foregroundStyle(Color.syMuted)
                .welcomeStage(1.3 * pace)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct WelcomeFeature {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    static let all = [
        WelcomeFeature(icon: "tray.full.fill", color: .sySky, title: "Inbox for reviews", detail: "Review requests, mentions and your PRs in one live list."),
        WelcomeFeature(icon: "arrow.triangle.merge", color: .syViolet, title: "Review & merge", detail: "Diffs, threads and checks — no browser tab needed."),
        WelcomeFeature(icon: "wand.and.sparkles", color: .syCoral, title: "Fix with agent", detail: "Hand a failing check or review comment to an agent.")
    ]
}

private struct WelcomeFeatures: View {
    let pace: Double

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(WelcomeFeature.all.enumerated()), id: \.offset) { index, feature in
                VStack(alignment: .leading, spacing: 8) {
                    IconTile(systemImage: feature.icon, color: feature.color, size: 28)
                    Text(feature.title)
                        .font(.syHeadline)
                        .foregroundStyle(Color.syText)
                    Text(feature.detail)
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(radius: 12)
                .accessibilityElement(children: .combine)
                .welcomeStage((1.5 + Double(index) * 0.1) * pace)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()

    private static let blobs: [(color: Color, x: Double, y: Double, phase: Double, speed: Double)] = [
        (.syViolet, 0.18, 0.12, 0, 0.11),
        (.sySky, 0.86, 0.3, 2.1, 0.09),
        (.syCoral, 0.4, 0.95, 4.2, 0.07)
    ]

    var body: some View {
        ZStack {
            Color(nsColor: Theme.isBrand ? .syWindow : .windowBackgroundColor)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: Motion.reduced)) { context in
                let t = Motion.reduced ? 0 : context.date.timeIntervalSince(start)
                let strength = scheme == .dark ? 0.2 : 0.13
                Canvas { ctx, size in
                    let radius = max(size.width, size.height) * 0.6
                    for blob in Self.blobs {
                        let center = CGPoint(
                            x: size.width * (blob.x + 0.1 * cos(t * blob.speed + blob.phase)),
                            y: size.height * (blob.y + 0.08 * sin(t * blob.speed * 0.8 + blob.phase))
                        )
                        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                        ctx.fill(
                            Path(ellipseIn: rect),
                            with: .radialGradient(Gradient(colors: [blob.color.opacity(strength), blob.color.opacity(0)]), center: center, startRadius: 0, endRadius: radius)
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct WelcomeStage: ViewModifier {
    let delay: Double
    let enabled: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown || Motion.reduced ? 0 : 12)
                .onAppear {
                    guard !shown else { return }
                    withAnimation(Motion.rowIn(delay: delay)) { shown = true }
                }
        } else {
            content
        }
    }
}

private extension View {
    func welcomeStage(_ delay: Double, enabled: Bool = true) -> some View {
        modifier(WelcomeStage(delay: delay, enabled: enabled))
    }
}
