import Combine
import SwiftUI
import UIKit

@MainActor
final class IslandPresenter: ObservableObject {
    static let shared = IslandPresenter()

    @Published private(set) var toast: FeedbackCenter.Toast?
    @Published private(set) var expanded = false
    @Published private(set) var topInset: CGFloat = 0
    var interactiveRect: CGRect = .zero { didSet { window?.interactiveRect = interactiveRect } }

    private var window: IslandWindow?
    private var cancellable: AnyCancellable?
    private var removal: Task<Void, Never>?
    private weak var feedback: FeedbackCenter?

    func install(feedback: FeedbackCenter) {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        self.feedback = feedback
        let window = IslandWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = IslandHostController(rootView: IslandHost(presenter: self))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        cancellable = feedback.$toast.receive(on: RunLoop.main).sink { [weak self] next in self?.update(next) }
    }

    private var mainWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow && !($0 is IslandWindow) }
    }

    private func update(_ next: FeedbackCenter.Toast?) {
        removal?.cancel()
        if let next {
            if let main = mainWindow {
                topInset = main.safeAreaInsets.top
                window?.overrideUserInterfaceStyle = main.traitCollection.userInterfaceStyle
            }
            if toast != nil, expanded {
                withAnimation(.snappy(duration: 0.25)) { toast = next }
                return
            }
            toast = next
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.52, dampingFraction: 0.76)) { self.expanded = true }
            }
        } else {
            guard toast != nil else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) { expanded = false }
            interactiveRect = .zero
            removal = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(480))
                guard !Task.isCancelled, !self.expanded else { return }
                self.toast = nil
            }
        }
    }

    func dismiss() {
        feedback?.dismissToast()
    }
}

final class IslandWindow: UIWindow {
    var interactiveRect: CGRect = .zero

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        interactiveRect.insetBy(dx: -6, dy: -6).contains(point)
    }
}

final class IslandHostController: UIHostingController<IslandHost> {
    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
}

struct IslandGeometry {
    let hasIsland: Bool
    let island: CGRect
    let toast: CGRect

    init(width: CGFloat, topInset: CGFloat) {
        hasIsland = topInset >= 51
        let islandWidth: CGFloat = 125
        let islandHeight: CGFloat = 37
        island = CGRect(x: (width - islandWidth) / 2, y: 11, width: islandWidth, height: islandHeight)
        let toastWidth = min(width - 24, 380)
        let top = hasIsland ? island.maxY + 8 : max(topInset, 20) + 6
        toast = CGRect(x: (width - toastWidth) / 2, y: top, width: toastWidth, height: 56)
    }

    var collapsed: CGRect {
        hasIsland ? island : CGRect(x: toast.midX - 60, y: -60, width: 120, height: 36)
    }
}

struct IslandHost: View {
    @ObservedObject var presenter: IslandPresenter

    var body: some View {
        GeometryReader { geo in
            let geometry = IslandGeometry(width: geo.size.width, topInset: presenter.topInset)
            let rect = presenter.expanded ? geometry.toast : geometry.collapsed
            ZStack(alignment: .topLeading) {
                if let toast = presenter.toast {
                    IslandGlassToast(toast: toast, expanded: presenter.expanded, fromIsland: geometry.hasIsland) {
                        toast.action?()
                        presenter.dismiss()
                    } dismiss: {
                        presenter.dismiss()
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: presenter.expanded, initial: true) { _, expanded in
                presenter.interactiveRect = expanded ? geometry.toast : .zero
            }
        }
        .ignoresSafeArea()
    }
}

private struct IslandGlassToast: View {
    let toast: FeedbackCenter.Toast
    let expanded: Bool
    let fromIsland: Bool
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(.clear)
                .pyGlass(in: Capsule(), tint: tint.opacity(0.12), interactive: true, fallback: MobileTheme.card)
                .opacity(expanded ? 1 : 0)
                .animation(expanded ? .easeOut(duration: 0.35).delay(0.08) : .easeIn(duration: 0.2), value: expanded)
            Capsule()
                .fill(.black)
                .opacity(fromIsland ? (expanded ? 0 : 1) : 0)
                .animation(expanded ? .easeOut(duration: 0.32).delay(0.1) : .easeIn(duration: 0.18).delay(0.1), value: expanded)
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(L(toast.message))
                    .mobileFont(size: 13, weight: .medium)
                    .foregroundStyle(MobileTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let title = toast.actionTitle {
                    Button(title, action: perform).mobileFont(size: 13, weight: .bold).foregroundStyle(MobileTheme.accent)
                }
            }
            .padding(.horizontal, 18)
            .opacity(expanded ? 1 : 0)
            .blur(radius: expanded ? 0 : 4)
            .animation(expanded ? .easeOut(duration: 0.25).delay(0.16) : .easeIn(duration: 0.1), value: expanded)
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(expanded ? (GlassSupport.isAvailable ? 0.08 : 0.12) : 0), radius: 14, y: 6)
        .contentShape(Capsule())
        .onTapGesture { if toast.actionTitle == nil { dismiss() } }
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in if value.translation.height < -8 { dismiss() } })
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
