import Combine
import SwiftUI
import UIKit

@MainActor
final class IslandPresenter: ObservableObject {
    static let shared = IslandPresenter()

    enum Phase: Equatable { case idle, showing, shown, hiding }

    @Published private(set) var toast: FeedbackCenter.Toast?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var phaseStart = Date.distantPast
    var interactiveRect: CGRect = .zero { didSet { window?.interactiveRect = interactiveRect } }

    private var window: IslandWindow?
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private weak var feedback: FeedbackCenter?

    static let showDuration = 0.8
    static let hideDuration = 0.5

    func install(feedback: FeedbackCenter) {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        self.feedback = feedback
        let window = IslandWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = IslandHostController(rootView: IslandHost(presenter: self, feedback: feedback))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        cancellable = feedback.$toast.receive(on: RunLoop.main).sink { [weak self] next in self?.update(next) }
    }

    private func update(_ next: FeedbackCenter.Toast?) {
        if let next {
            if let window, let main = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: { $0.isKeyWindow }) {
                window.overrideUserInterfaceStyle = main.traitCollection.userInterfaceStyle
            }
            hideTask?.cancel()
            if toast != nil, phase == .shown || phase == .showing {
                withAnimation(.snappy(duration: 0.25)) { toast = next }
                return
            }
            toast = next
            phaseStart = Date()
            phase = .showing
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.showDuration))
                if self.phase == .showing { self.phase = .shown }
            }
        } else {
            guard toast != nil, phase != .hiding, phase != .idle else { return }
            phaseStart = Date()
            phase = .hiding
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.hideDuration))
                guard !Task.isCancelled, self.phase == .hiding else { return }
                self.phase = .idle
                self.toast = nil
                self.interactiveRect = .zero
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
    let pill: CGRect

    init(size: CGSize, topInset: CGFloat) {
        hasIsland = topInset >= 51
        let islandWidth: CGFloat = 124
        let islandHeight: CGFloat = 36
        let islandTop: CGFloat = 11.5
        island = CGRect(x: (size.width - islandWidth) / 2, y: islandTop, width: islandWidth, height: islandHeight)
        let width = min(size.width - 24, 380)
        let top = hasIsland ? island.maxY + 10 : max(topInset, 20) + 6
        pill = CGRect(x: (size.width - width) / 2, y: top, width: width, height: 58)
    }
}

struct IslandHost: View {
    @ObservedObject var presenter: IslandPresenter
    let feedback: FeedbackCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let geometry = IslandGeometry(size: geo.size, topInset: geo.safeAreaInsets.top)
            TimelineView(.animation(paused: presenter.phase == .idle || presenter.phase == .shown)) { context in
                let frame = Self.frame(phase: presenter.phase, start: presenter.phaseStart, now: context.date, geometry: geometry, reduceMotion: reduceMotion)
                ZStack(alignment: .topLeading) {
                    if presenter.phase != .idle {
                        if geometry.hasIsland && !reduceMotion {
                            Canvas { canvas, _ in
                                canvas.addFilter(.alphaThreshold(min: 0.5, color: .black))
                                canvas.addFilter(.blur(radius: 7))
                                canvas.drawLayer { layer in
                                    layer.fill(Path(roundedRect: geometry.island.insetBy(dx: 3, dy: 2), cornerRadius: geometry.island.height / 2), with: .color(.black))
                                    layer.fill(Path(roundedRect: frame.blob, cornerRadius: min(frame.blob.height, frame.blob.width) / 2), with: .color(.black))
                                }
                            }
                            .allowsHitTesting(false)
                        }
                        RoundedRectangle(cornerRadius: frame.blob.height / 2, style: .continuous)
                            .fill(.black)
                            .frame(width: frame.blob.width, height: frame.blob.height)
                            .offset(x: frame.blob.minX, y: frame.blob.minY)
                            .opacity(frame.solid)
                            .shadow(color: .black.opacity(0.25 * frame.content), radius: 16, y: 8)
                        if let toast = presenter.toast {
                            IslandToastContent(toast: toast) {
                                toast.action?()
                                presenter.dismiss()
                            } dismiss: {
                                presenter.dismiss()
                            }
                            .frame(width: geometry.pill.width, height: geometry.pill.height)
                            .offset(x: geometry.pill.minX, y: geometry.pill.minY)
                            .opacity(frame.content)
                            .scaleEffect(0.9 + 0.1 * frame.content, anchor: .top)
                            .allowsHitTesting(presenter.phase == .shown || presenter.phase == .showing)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .onChange(of: presenter.phase, initial: true) { _, phase in
                presenter.interactiveRect = phase == .idle || phase == .hiding ? .zero : geometry.pill
            }
        }
        .ignoresSafeArea()
    }

    struct Frame {
        var blob: CGRect
        var content: Double
        var solid: Double
    }

    static func frame(phase: IslandPresenter.Phase, start: Date, now: Date, geometry: IslandGeometry, reduceMotion: Bool) -> Frame {
        let pill = geometry.pill
        let elapsed = now.timeIntervalSince(start)
        if !geometry.hasIsland || reduceMotion {
            let duration = phase == .hiding ? IslandPresenter.hideDuration * 0.6 : IslandPresenter.showDuration * 0.6
            let raw = phase == .shown ? 1 : phase == .idle ? 0 : min(1, elapsed / duration)
            let t = phase == .hiding ? 1 - ease(raw) : ease(raw)
            let drop = reduceMotion ? 0 : (1 - t) * -(pill.maxY + 10)
            return Frame(blob: pill.offsetBy(dx: 0, dy: drop), content: t, solid: 1)
        }
        let progress: Double
        switch phase {
        case .idle: progress = 0
        case .shown: progress = 1
        case .showing: progress = min(1, elapsed / IslandPresenter.showDuration)
        case .hiding: progress = 1 - min(1, elapsed / IslandPresenter.hideDuration)
        }
        let island = geometry.island
        let dropSize: CGFloat = 26
        let drip = easeInOut(min(1, progress / 0.6))
        let stretch = CGFloat(sin(Double.pi * drip)) * 16
        let spread = springy(max(0, (progress - 0.55) / 0.45))
        let dropY = island.midY + (pill.midY - island.midY) * drip
        let width = dropSize + (pill.width - dropSize) * spread
        let height = dropSize + stretch * (1 - spread) + (pill.height - dropSize) * spread
        let blob = CGRect(x: pill.midX - width / 2, y: dropY - height / 2, width: width, height: height)
        let content = max(0, min(1, (progress - 0.78) / 0.22))
        let solid = max(0, min(1, (progress - 0.68) / 0.22))
        return Frame(blob: blob, content: content, solid: solid)
    }

    private static func ease(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private static func easeInOut(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    private static func springy(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        return min(1.03, 1 - exp(-5 * t) * cos(4 * t))
    }
}

private struct IslandToastContent: View {
    let toast: FeedbackCenter.Toast
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.2))
                Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)
            Text(L(toast.message))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let title = toast.actionTitle {
                Button(action: perform) {
                    Text(L(title))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(tint, in: Capsule())
                }
                .buttonStyle(.pyPlain)
            }
        }
        .padding(.horizontal, 12)
        .contentShape(Capsule())
        .onTapGesture { if toast.actionTitle == nil { dismiss() } }
        .gesture(DragGesture(minimumDistance: 10).onEnded { value in if value.translation.height < -8 { dismiss() } })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(toast.actionTitle == nil ? [] : .isButton)
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
