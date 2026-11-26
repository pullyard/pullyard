import SwiftUI
import UIKit

@MainActor
final class FeedbackCenter: ObservableObject {
    enum Banner: Equatable {
        case offline
        case rateLimited(Date?)
        case notice(String)

        var message: String {
            switch self {
            case .offline: "You're offline. Showing saved data."
            case let .rateLimited(until): "GitHub rate limit reached\(until.map { " · resumes at \($0.formatted(date: .omitted, time: .shortened))" } ?? ""). Showing saved data."
            case let .notice(text): text
            }
        }
        var symbol: String {
            switch self {
            case .offline: "wifi.slash"
            case .rateLimited: "hourglass"
            case .notice: "exclamationmark.triangle"
            }
        }
    }

    struct Toast: Identifiable {
        enum Style { case success, info, error }
        let id = UUID()
        let key: String
        let style: Style
        let message: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
    }

    @Published var banner: Banner?
    @Published private(set) var toast: Toast?
    private var pending: [Toast] = []
    private var dismissTask: Task<Void, Never>?

    func success(_ message: String, key: String? = nil) {
        show(Toast(key: key ?? message, style: .success, message: message))
    }

    func info(_ message: String, key: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        show(Toast(key: key ?? message, style: .info, message: message, actionTitle: actionTitle, action: action))
    }

    func error(_ error: Error, key: String? = nil, retry: (() -> Void)? = nil) {
        guard !error.isCancellation else { return }
        if let github = error.asGitHubError {
            if github == .offline { banner = .offline; return }
            if github.isRateLimit { banner = .rateLimited(github.retryDate); return }
        }
        show(Toast(key: key ?? error.localizedDescription, style: .error, message: error.localizedDescription, actionTitle: retry == nil ? nil : "Retry", action: retry))
    }

    func show(_ toast: Toast) {
        if self.toast?.key == toast.key || pending.contains(where: { $0.key == toast.key }) { return }
        if self.toast == nil { present(toast) } else { pending.append(toast) }
    }

    func dismissToast() {
        dismissTask?.cancel()
        toast = nil
        if !pending.isEmpty { present(pending.removeFirst()) }
    }

    func clearAll() {
        dismissTask?.cancel()
        pending = []; toast = nil; banner = nil
    }

    private func present(_ next: Toast) {
        toast = next
        let generator = UINotificationFeedbackGenerator()
        switch next.style {
        case .success: generator.notificationOccurred(.success)
        case .error: generator.notificationOccurred(.error)
        case .info: break
        }
        UIAccessibility.post(notification: .announcement, argument: next.message)
        dismissTask?.cancel()
        let id = next.id
        let seconds = next.action == nil ? 3.2 : 6.0
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            withAnimation(.snappy) { self.dismissToast() }
        }
    }
}

struct FeedbackChrome: ViewModifier {
    @EnvironmentObject private var feedback: FeedbackCenter
    var onBannerTap: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let banner = feedback.banner {
                    Button { onBannerTap?() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: banner.symbol)
                            Text(L(banner.message)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if onBannerTap != nil { Image(systemName: "arrow.clockwise").accessibilityHidden(true) }
                        }
                        .mobileFont(size: 12, weight: .semibold)
                        .foregroundStyle(MobileTheme.amberInk)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .pyGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), tint: MobileTheme.amber.opacity(0.35), interactive: onBannerTap != nil, fallback: MobileTheme.amber.opacity(0.16))
                        .padding(.horizontal, 12).padding(.top, 4)
                    }
                    .buttonStyle(.pyPlain)
                    .accessibilityHint(onBannerTap == nil ? "" : "Double-tap to try again")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: feedback.banner)
    }
}

extension View {
    func feedbackChrome(onBannerTap: (() -> Void)? = nil) -> some View {
        modifier(FeedbackChrome(onBannerTap: onBannerTap))
    }
}
