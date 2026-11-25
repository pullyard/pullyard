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
                withAnimation(.spring(response: 0.5, dampingFraction: 0.74)) { self.expanded = true }
            }
        } else {
            guard toast != nil else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) { expanded = false }
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
    let card: CGRect

    init(width: CGFloat, topInset: CGFloat) {
        hasIsland = topInset >= 51
        let islandWidth: CGFloat = 125
        let islandHeight: CGFloat = 37
        island = CGRect(x: (width - islandWidth) / 2, y: 11, width: islandWidth, height: islandHeight)
        let cardWidth = min(width - 20, 390)
        if hasIsland {
            card = CGRect(x: (width - cardWidth) / 2, y: island.minY, width: cardWidth, height: 104)
        } else {
            card = CGRect(x: (width - cardWidth) / 2, y: max(topInset, 20) + 4, width: cardWidth, height: 64)
        }
    }

    var collapsed: CGRect {
        hasIsland ? island : CGRect(x: card.midX - 60, y: -60, width: 120, height: 36)
    }

    var expandedRadius: CGFloat { hasIsland ? 44 : 32 }
}

struct IslandHost: View {
    @ObservedObject var presenter: IslandPresenter

    var body: some View {
        GeometryReader { geo in
            let geometry = IslandGeometry(width: geo.size.width, topInset: presenter.topInset)
            let rect = presenter.expanded ? geometry.card : geometry.collapsed
            let radius = presenter.expanded ? geometry.expandedRadius : geometry.collapsed.height / 2
            ZStack(alignment: .topLeading) {
                if presenter.toast != nil {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.black)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .shadow(color: .black.opacity(presenter.expanded ? 0.28 : 0), radius: 18, y: 10)
                }
                if let toast = presenter.toast {
                    IslandCardContent(toast: toast, hasIsland: geometry.hasIsland, island: geometry.island) {
                        toast.action?()
                        presenter.dismiss()
                    } dismiss: {
                        presenter.dismiss()
                    }
                    .frame(width: geometry.card.width, height: geometry.card.height)
                    .offset(x: geometry.card.minX, y: geometry.card.minY)
                    .opacity(presenter.expanded ? 1 : 0)
                    .scaleEffect(presenter.expanded ? 1 : 0.6, anchor: .top)
                    .blur(radius: presenter.expanded ? 0 : 6)
                    .animation(presenter.expanded ? .easeOut(duration: 0.3).delay(0.12) : .easeIn(duration: 0.12), value: presenter.expanded)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onChange(of: presenter.expanded, initial: true) { _, expanded in
                presenter.interactiveRect = expanded ? geometry.card : .zero
            }
        }
        .ignoresSafeArea()
    }
}

private struct IslandCardContent: View {
    let toast: FeedbackCenter.Toast
    let hasIsland: Bool
    let island: CGRect
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasIsland {
                HStack {
                    ShipGlyph(size: 26)
                    Spacer()
                    badge
                }
                .padding(.horizontal, 20)
                .frame(height: island.height)
            }
            HStack(spacing: 12) {
                if !hasIsland { badge }
                Text(L(toast.message))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let title = toast.actionTitle {
                    Button(action: perform) {
                        Text(L(title))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(tint, in: Capsule())
                    }
                    .buttonStyle(.pyPlain)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { if toast.actionTitle == nil { dismiss() } }
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in if value.translation.height < -8 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(toast.actionTitle == nil ? [] : .isButton)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(tint.opacity(0.22))
            Image(systemName: symbol).font(.system(size: 13, weight: .heavy)).foregroundStyle(tint)
        }
        .frame(width: 28, height: 28)
    }

    private var symbol: String {
        switch toast.style { case .success: "checkmark"; case .info: "info"; case .error: "exclamationmark" }
    }

    private var tint: Color {
        switch toast.style {
        case .success: Color(red: 0.384, green: 0.769, blue: 0.561)
        case .info: Color(red: 0.357, green: 0.722, blue: 0.925)
        case .error: Color(red: 0.941, green: 0.459, blue: 0.388)
        }
    }
}
