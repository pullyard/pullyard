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
                            Text(banner.message).lineLimit(2).multilineTextAlignment(.leading)
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
            .overlay(alignment: .bottom) {
                if let toast = feedback.toast {
                    ToastView(toast: toast) {
                        toast.action?()
                        withAnimation(.snappy) { feedback.dismissToast() }
                    } dismiss: {
                        withAnimation(.snappy) { feedback.dismissToast() }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: feedback.banner)
            .animation(.snappy, value: feedback.toast?.id)
    }
}

private struct ToastView: View {
    let toast: FeedbackCenter.Toast
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.message).mobileFont(size: 13, weight: .medium).foregroundStyle(MobileTheme.ink).lineLimit(3)
            Spacer(minLength: 4)
            if let title = toast.actionTitle {
                Button(title, action: perform).mobileFont(size: 13, weight: .bold).foregroundStyle(MobileTheme.accent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .pyGlass(in: Capsule(), tint: tint.opacity(0.12), interactive: true)
        .shadow(color: .black.opacity(GlassSupport.isAvailable ? 0.08 : 0.12), radius: 14, y: 6)
        .onTapGesture { if toast.actionTitle == nil { dismiss() } }
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in if value.translation.height > 10 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(toast.actionTitle == nil ? [] : .isButton)
    }

    private var symbol: String {
        switch toast.style { case .success: "checkmark.circle.fill"; case .info: "info.circle.fill"; case .error: "exclamationmark.circle.fill" }
    }
    private var tint: Color {
        switch toast.style { case .success: MobileTheme.green; case .info: MobileTheme.accent; case .error: MobileTheme.coral }
    }
}

extension View {
    func feedbackChrome(onBannerTap: (() -> Void)? = nil) -> some View {
        modifier(FeedbackChrome(onBannerTap: onBannerTap))
    }
}
