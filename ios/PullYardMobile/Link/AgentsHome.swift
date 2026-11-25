import SwiftUI

struct AgentsHome: View {
    @ObservedObject private var link = LinkClient.shared

    private var showsSessions: Bool {
        guard link.mac != nil else { return false }
        return link.isConnected || !link.sessions.isEmpty || !link.history.isEmpty
    }

    var body: some View {
        Group {
            if showsSessions {
                AgentSessionsView()
            } else {
                AgentsConnectView()
            }
        }
        .animation(.snappy, value: showsSessions)
        .accountButton()
    }
}

private struct AgentsConnectView: View {
    @ObservedObject private var link = LinkClient.shared
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter

    private enum Mode { case unpaired, connecting, offline }

    private var mode: Mode {
        guard link.mac != nil else { return .unpaired }
        if case .connecting = link.status { return .connecting }
        return .offline
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                ConnectionIllustration(active: mode == .connecting, linked: false)
                    .padding(.top, 36)
                VStack(spacing: 10) {
                    Text(LocalizedStringKey(title))
                        .mobileFont(size: 26, weight: .regular, design: .serif)
                        .foregroundStyle(MobileTheme.ink)
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey(message))
                        .mobileFont(size: 15)
                        .foregroundStyle(MobileTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                if mode == .unpaired {
                    VStack(alignment: .leading, spacing: 14) {
                        step(1, "Open PullYard on your Mac")
                        step(2, "Go to Settings → iPhone and tap Show pairing code")
                        step(3, "Scan it from Settings → Mac on this iPhone")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.large, style: .continuous), fallback: MobileTheme.card)
                }
                VStack(spacing: 10) {
                    if mode == .offline {
                        primary("Try again", symbol: "arrow.clockwise") { link.connectIfNeeded() }
                        secondary("Open Settings", symbol: "gearshape") { openSettings() }
                    } else if mode == .unpaired {
                        primary("Pair with your Mac", symbol: "qrcode.viewfinder") { openSettings() }
                    } else {
                        secondary("Open Settings", symbol: "gearshape") { openSettings() }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(BrandBackdrop())
        .navigationTitle("Agents")
        .task { if link.mac != nil { link.connectIfNeeded() } }
        .animation(.snappy, value: mode)
    }

    private var title: String {
        switch mode {
        case .unpaired: "Your Mac's agent, in your pocket"
        case .connecting: "Connecting to your Mac…"
        case .offline: "Can't reach your Mac"
        }
    }

    private var message: String {
        switch mode {
        case .unpaired: return "Pair this iPhone with PullYard on your Mac to start agent fixes, follow the chat live and answer when it needs you."
        case .connecting: return "Hang on, this usually takes a second."
        case .offline:
            if case let .failed(reason) = link.status { return reason }
            return "Make sure PullYard is open on your Mac with iPhone access turned on."
        }
    }

    private func openSettings() {
        router.popToRoot(.settings)
        router.showSettings = true
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .mobileFont(size: 13, weight: .bold, design: .rounded)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(MobileTheme.accentFill, in: Circle())
            Text(LocalizedStringKey(text)).mobileFont(size: 15).foregroundStyle(MobileTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .mobileFont(size: 16, weight: .semibold)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Capsule())
                .pyGlass(in: Capsule(), tint: MobileTheme.coral, interactive: true, fallback: MobileTheme.coral)
        }
        .buttonStyle(.pyPlain)
    }

    private func secondary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .mobileFont(size: 15, weight: .semibold)
                .foregroundStyle(MobileTheme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Capsule())
                .pyGlass(in: Capsule(), interactive: true, fallback: MobileTheme.card)
        }
        .buttonStyle(.pyPlain)
    }
}

private struct ConnectionIllustration: View {
    let active: Bool
    let linked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            device("iphone")
            TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
                let t = context.date.timeIntervalSinceReferenceDate * (active ? 2.2 : 1.1)
                HStack(spacing: 7) {
                    ForEach(0..<5, id: \.self) { index in
                        let wave = (sin(t - Double(index) * 0.7) + 1) / 2
                        Circle()
                            .fill(LinearGradient(colors: [MobileTheme.violet, MobileTheme.sky], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 7, height: 7)
                            .opacity(reduceMotion ? 0.6 : 0.25 + 0.75 * wave)
                            .scaleEffect(reduceMotion ? 1 : 0.75 + 0.35 * wave)
                    }
                }
            }
            .frame(width: 72)
            device("laptopcomputer")
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func device(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(LinearGradient(colors: [MobileTheme.violet, MobileTheme.sky], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 76, height: 76)
            .pyGlass(in: Circle(), fallback: MobileTheme.card)
            .overlay(Circle().stroke(MobileTheme.line))
    }
}
