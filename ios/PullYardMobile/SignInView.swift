import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var revealToken = false
    @State private var showingGuide = false
    @State private var showingDeviceFlow = false
    @State private var showOwnApp = false
    @AppStorage(DeviceFlow.customClientKey) private var customClientID = ""
    @AppStorage("mobile.onboarded") private var onboarded = false
    @FocusState private var focused: Bool

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tokenHint: (text: String, symbol: String, color: Color)? {
        if trimmed.hasPrefix("github_pat_") { return ("Fine-grained tokens can't read notifications, so the Inbox will stay empty. A classic token (ghp_) works everywhere.", "exclamationmark.triangle.fill", MobileTheme.amber) }
        if trimmed.hasPrefix("ghp_") { return ("Classic token detected.", "checkmark.circle.fill", MobileTheme.green) }
        if trimmed.hasPrefix("gho_") { return ("OAuth token detected.", "checkmark.circle.fill", MobileTheme.green) }
        if trimmed.count > 8 { return ("This doesn't look like a GitHub token. It usually starts with ghp_.", "info.circle.fill", MobileTheme.amber) }
        return nil
    }

    var body: some View {
        ZStack {
            HarborBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 18) {
                        LogoDrawOn(size: 96, duration: 1.8)
                        Text("Your reviews,\nwithin reach.")
                            .mobileFont(size: 38, weight: .regular, design: .serif).tracking(-1).foregroundStyle(.white)
                        Text("Triage pull requests, follow checks and reply to your team — wherever you are.")
                            .mobileFont(size: 16).lineSpacing(4).foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(.top, 36)

                    if !DeviceFlow.clientID.isEmpty {
                        Button { showingDeviceFlow = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub").mobileFont(size: 17, weight: .semibold)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Capsule())
                            .pyGlass(in: Capsule(), tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
                        }
                        .buttonStyle(.pyPlain)
                        .disabled(model.isSigningIn)
                        Text("or paste a personal access token").mobileFont(size: 13, weight: .medium).foregroundStyle(.white.opacity(0.65)).frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Connect GitHub").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                        HStack(spacing: 8) {
                            Group {
                                if revealToken { TextField("Personal access token", text: $token) }
                                else { SecureField("Personal access token", text: $token) }
                            }
                            .focused($focused)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .submitLabel(.go)
                            .onSubmit(connect)
                            .mobileFont(size: 15, design: .monospaced)
                            if token.isEmpty {
                                PasteButton(payloadType: String.self) { values in
                                    if let value = values.first { token = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                                }
                                .labelStyle(.iconOnly)
                                .buttonBorderShape(.capsule)
                                .tint(MobileTheme.accentFill)
                            } else {
                                Button { revealToken.toggle() } label: { Image(systemName: revealToken ? "eye.slash" : "eye").foregroundStyle(MobileTheme.muted).pyHitArea(minSize: 36) }
                                    .accessibilityLabel(revealToken ? "Hide token" : "Show token")
                            }
                        }
                        .padding(14)
                        .background(MobileTheme.card.opacity(GlassSupport.isAvailable ? 0.75 : 1), in: Capsule())
                        .overlay(Capsule().stroke(focused ? MobileTheme.accent.opacity(0.6) : MobileTheme.line, lineWidth: 1))

                        if let hint = tokenHint {
                            Label(hint.text, systemImage: hint.symbol)
                                .mobileFont(size: 13)
                                .foregroundStyle(hint.color == MobileTheme.green ? MobileTheme.green : MobileTheme.amberInk)
                                .transition(.opacity)
                        }

                        Button(action: connect) {
                            HStack(spacing: 10) {
                                if model.isSigningIn { PullYardLoader(size: 32, style: .monochrome(.white)) }
                                Text(model.isSigningIn ? "Connecting…" : "Connect GitHub").mobileFont(size: 16, weight: .semibold)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(.white)
                            .contentShape(Capsule())
                            .pyGlass(in: Capsule(), tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
                        }
                        .buttonStyle(.pyPlain)
                        .disabled(model.isSigningIn || trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.55 : 1)

                        DisclosureGroup(isExpanded: $showOwnApp) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("OAuth app client ID", text: $customClientID)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .mobileFont(size: 14, design: .monospaced)
                                    .padding(12)
                                    .background(MobileTheme.card.opacity(0.8), in: Capsule())
                                Text("Create an OAuth app in GitHub → Settings → Developer settings, enable Device Flow, then paste its client ID to sign in through the browser.")
                                    .mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Use your own OAuth app").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                        }
                        .tint(MobileTheme.muted)
                        Button("How to create a token") { showingGuide = true }
                            .mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.accent).frame(maxWidth: .infinity)
                    }
                    .padding(20)
                    .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.large + 4, style: .continuous))
                    .animation(.snappy, value: tokenHint?.text)

                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill").foregroundStyle(MobileTheme.green)
                        Text("Your token stays in this iPhone's Keychain. PullYard has no server and never stores your GitHub data elsewhere.")
                            .mobileFont(size: 13).lineSpacing(3).foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 4)
                }
                .padding(.horizontal, 24).padding(.bottom, 32).frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(nil)
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
            OnboardingView { onboarded = true }
        }
        .sheet(isPresented: $showingGuide) { TokenGuideView() }
        .sheet(isPresented: $showingDeviceFlow) {
            DeviceFlowSheet(clientID: DeviceFlow.clientID) { token in
                await model.signIn(token)
            }
        }
        .alert("GitHub sign-in", isPresented: Binding(get: { model.signInError != nil }, set: { if !$0 { model.signInError = nil } })) {
            Button("OK", role: .cancel) { model.signInError = nil }
        } message: { Text(model.signInError ?? "Check the token and try again.") }
    }

    private func connect() {
        guard !trimmed.isEmpty, !model.isSigningIn else { return }
        focused = false
        Task {
            await model.signIn(token)
            if model.isSignedIn { token = "" }
        }
    }
}

struct HarborBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(uiColor: UIColor(hex: 0x1A2540)), MobileTheme.navy, Color(uiColor: UIColor(hex: 0x071022))], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 0.42, green: 0.33, blue: 0.84).opacity(0.45)).frame(width: geo.size.width * 0.9).blur(radius: 90)
                    .offset(x: -geo.size.width * 0.35 + (drift ? 30 : 0), y: -geo.size.height * 0.28)
                Circle().fill(Color(red: 0.22, green: 0.74, blue: 0.97).opacity(0.35)).frame(width: geo.size.width * 0.8).blur(radius: 90)
                    .offset(x: geo.size.width * 0.4 - (drift ? 24 : 0), y: -geo.size.height * 0.05)
                Circle().fill(Color(red: 0.85, green: 0.32, blue: 0.25).opacity(0.25)).frame(width: geo.size.width * 0.7).blur(radius: 100)
                    .offset(x: geo.size.width * 0.15, y: geo.size.height * 0.42 + (drift ? -20 : 0))
                WaveLines()
                    .stroke(Color(red: 0.49, green: 0.83, blue: 0.99).opacity(0.18), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(height: 120)
                    .offset(y: geo.size.height * 0.38)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
        .accessibilityHidden(true)
    }
}

private struct WaveLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for row in 0..<3 {
            let y = rect.minY + CGFloat(row) * rect.height / 3 + 20
            path.move(to: CGPoint(x: rect.minX - 20, y: y))
            var x = rect.minX - 20
            while x < rect.maxX + 20 {
                path.addQuadCurve(to: CGPoint(x: x + 60, y: y), control: CGPoint(x: x + 30, y: y + (row % 2 == 0 ? -10 : 10)))
                x += 60
            }
        }
        return path
    }
}

struct TokenGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,notifications&description=PullYard%20iPhone")!

    var body: some View {
        NavigationStack {
            List {
                Section("Create a classic token") {
                    Label("Open GitHub token settings", systemImage: "1.circle.fill")
                    Label("Keep the repo and notifications scopes selected", systemImage: "2.circle.fill")
                    Label("Generate, copy, then paste it here", systemImage: "3.circle.fill")
                }
                .foregroundStyle(MobileTheme.ink)
                .pyRow()
                Section {
                    Text("repo lets PullYard read pull requests and post reviews or comments in repositories you can access. notifications lets the Inbox load and update GitHub notifications. The token stays on this device.")
                        .mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
                    Link(destination: tokenURL) { Label("Open GitHub settings", systemImage: "arrow.up.right.square") }
                } footer: { Text("You can revoke this token anytime in GitHub → Settings → Developer settings → Personal access tokens.") }
                .pyRow()
            }
            .pyListStyle()
            .navigationTitle("Connect securely").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .pySheetStyle()
        .presentationDetents([.medium, .large])
    }
}
