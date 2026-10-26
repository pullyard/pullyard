import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var app
    let tab: ClaudeTab
    let chat: ChatSession
    @State private var follow = ChatFollow()
    @State private var awayCount: Int?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if chat.items.isEmpty {
                            ChatWelcome(chat: chat, folder: tab.folder)
                        }
                        ForEach(chat.displayItems) { entry in
                            Group {
                                switch entry {
                                case .item(let item):
                                    ChatItemView(item: item, chat: chat, folder: tab.folder)
                                case .tools(let id, let steps):
                                    ToolGroupView(id: id, steps: steps, chat: chat, folder: tab.folder)
                                }
                            }
                            .id(entry.id)
                            .transition(.rise)
                        }
                        if let url = chat.createdPR {
                            CreatedPRCard(url: url)
                                .id("created-pr")
                                .transition(.pop)
                        }
                        if chat.busy {
                            WorkingIndicator(chat: chat)
                                .transition(.opacity)
                        }
                        if let e = chat.lastError {
                            ErrorBanner(text: e, retry: { app.claude.restart(tab) }, reconnect: { app.claude.reconnect(tab) })
                                .transition(.pop)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .scrollTargetLayout()
                    .allowsHitTesting(!follow.scrolling)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .animation(unlessPinned(Motion.smooth), value: chat.items.count)
                    .animation(unlessPinned(Motion.fade), value: chat.busy)
                    .animation(Motion.spring, value: chat.lastError)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
                    .background(ChatScrollObserver(follow: follow))
                }
                .scrollPosition(id: topAnchor)
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: ChatViewportKey.self, value: g.size.height)
                    }
                }
                .modifier(InitialBottomAnchor())
                .onPreferenceChange(ChatViewportKey.self) { follow.viewportHeight = $0 }
                .onChange(of: chat.items.count) {
                    if case .user? = chat.items.last { follow.stick = true }
                    scrollDown(proxy)
                }
                .onChange(of: chat.busy) { scrollDown(proxy) }
                .onChange(of: chat.lastError) { scrollDown(proxy) }
                .onChange(of: chat.pendingCount) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { scrollDown(proxy) }
                }
                .onChange(of: follow.resizeTick) { keepPosition(proxy) }
                .onAppear { jumpToBottom(proxy) }
                .onChange(of: tab.id) { jumpToBottom(proxy) }
                .overlay(alignment: .bottom) {
                    if !follow.stick, !chat.items.isEmpty {
                        JumpToLatestButton(newCount: max(0, chat.items.count - (awayCount ?? chat.items.count))) {
                            follow.stick = true
                            withAnimation(Motion.reduced ? nil : .spring(response: 0.55, dampingFraction: 0.86)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                        .padding(.bottom, 16)
                        .transition(Motion.reduced ? .opacity : .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.6)).combined(with: .offset(y: 14)),
                            removal: .opacity.combined(with: .scale(scale: 0.85)).combined(with: .offset(y: 10))
                        ))
                    }
                }
                .animation(Motion.reduced ? nil : .spring(response: 0.42, dampingFraction: 0.7), value: follow.stick)
                .onChange(of: follow.stick) { _, stick in awayCount = stick ? nil : chat.items.count }
            }
            if chat.sleeping && !chat.running {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz").foregroundStyle(Color.syMuted)
                    Text("Session is sleeping — process stopped, memory freed. A new message resumes it.")
                        .font(.syCallout)
                        .foregroundStyle(Color.syMuted)
                    Spacer()
                    Button("Wake up") { chat.wake() }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.syText.opacity(0.03))
                .overlay(alignment: .top) { Rectangle().fill(Color.syLine).frame(height: 1) }
            }
            ChatComposer(tab: tab, chat: chat)
        }
        .background(Theme.isBrand ? Color.syPanel : Color(nsColor: .textBackgroundColor).opacity(0.35))
    }

    private var topAnchor: Binding<String?> {
        Binding(get: { follow.stick ? nil : follow.topID }, set: { id in
            follow.topID = id
            if !follow.resizing { follow.keptTopID = id }
        })
    }

    private func unlessPinned(_ animation: Animation?) -> Animation? {
        follow.stick ? nil : animation
    }

    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        follow.stick = true
        proxy.scrollTo("bottom", anchor: .bottom)
        for delay in [0.05, 0.2, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func keepPosition(_ proxy: ScrollViewProxy) {
        guard !follow.stick, let id = follow.keptTopID else { return }
        proxy.scrollTo(id, anchor: .top)
        for delay in [0.05, 0.15, 0.3, 0.5, 0.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !follow.stick else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        guard follow.stick else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

@Observable
final class ChatFollow {
    var stick = true
    var scrolling = false
    @ObservationIgnored var topID: String?
    @ObservationIgnored var keptTopID: String?
    var resizeTick = 0
    @ObservationIgnored var resizing = false
    @ObservationIgnored var viewportHeight: CGFloat = 0
}

private struct ChatScrollObserver: NSViewRepresentable {
    let follow: ChatFollow

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.follow = follow
        return v
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.follow = follow
    }

    final class ObserverView: NSView {
        weak var follow: ChatFollow?
        private var monitor: Any?
        private var scrollEnd: DispatchWorkItem?
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var lastWidth: CGFloat = 0
        private var restoreUntil = Date.distantPast

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        private func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            scroll = nil
        }

        private func attach() {
            guard monitor == nil, let s = enclosingScrollView else { return }
            scroll = s
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
            lastWidth = s.contentView.bounds.width
            let clip = s.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            s.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutChanged() }
            })
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutChanged(resized: true) }
            })
            if let doc = s.documentView {
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutChanged(resized: true) }
                })
            }
        }

        private func layoutChanged(resized: Bool = false) {
            guard let s = scroll, let doc = s.documentView, let follow else { return }
            let clip = s.contentView
            let width = clip.bounds.width
            if abs(width - lastWidth) > 0.5 {
                lastWidth = width
                restoreUntil = Date().addingTimeInterval(0.8)
                if !follow.resizing {
                    follow.resizing = true
                    follow.resizeTick += 1
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                    guard let self, self.restoreUntil < Date() else { return }
                    self.follow?.resizing = false
                }
            }
            guard follow.stick, resized || restoreUntil > Date() else { return }
            let y = max(0, doc.frame.height - clip.bounds.height)
            guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            s.reflectScrolledClipView(clip)
        }

        private var distanceToBottom: CGFloat {
            guard let s = scroll, let doc = s.documentView else { return 0 }
            let clip = s.contentView
            return doc.frame.height - clip.bounds.maxY
        }

        private func handle(_ event: NSEvent) {
            guard let s = scroll, let window = s.window, event.window === window else { return }
            let point = s.convert(event.locationInWindow, from: nil)
            guard s.bounds.contains(point) else { return }
            if follow?.scrolling == false { follow?.scrolling = true }
            scrollEnd?.cancel()
            let end = DispatchWorkItem { [weak self] in self?.follow?.scrolling = false }
            scrollEnd = end
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: end)
            if event.scrollingDeltaY > 0 {
                if follow?.stick == true { follow?.stick = false }
                return
            }
            guard event.scrollingDeltaY < 0 || event.phase == .ended || event.momentumPhase == .ended else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let follow = self.follow else { return }
                if !follow.stick, self.distanceToBottom < 24 { follow.stick = true }
            }
        }
    }
}

struct JumpToLatestButton: View {
    var newCount = 0
    let action: () -> Void
    @State private var hover = false
    @State private var pressed = false
    @State private var start = Date()

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.syRaised)
                    .shadow(color: .black.opacity(hover ? 0.32 : 0.2), radius: hover ? 14 : 9, y: hover ? 6 : 3)
                let animate = !Motion.reduced && (hover || newCount > 0)
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animate)) { context in
                    let t = context.date.timeIntervalSince(start)
                    ZStack {
                        DiveLogo(time: animate ? t : nil)
                            .clipShape(Circle())
                        Circle()
                            .strokeBorder(
                                AngularGradient(colors: [BrandMark.violet, BrandMark.sky, BrandMark.violet.opacity(0.25), BrandMark.violet], center: .center),
                                lineWidth: 1.5
                            )
                            .rotationEffect(.degrees(animate ? t * 70 : 0))
                    }
                    .drawingGroup()
                }
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if newCount > 0 {
                    Text(newCount > 99 ? "99+" : "\(newCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(LinearGradient(colors: [BrandMark.violet, BrandMark.sky], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        .overlay(Capsule().strokeBorder(Color.syPanel, lineWidth: 2))
                        .offset(x: 6, y: -4)
                        .transition(.scale.combined(with: .opacity))
                        .id(newCount)
                }
            }
            .scaleEffect(pressed ? 0.92 : (hover ? 1.06 : 1))
            .offset(y: hover ? -2 : 0)
        }
        .buttonStyle(PressReporter(pressed: $pressed))
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: newCount)
        .help(newCount > 0 ? "\(newCount) new — jump to the latest message" : "Jump to the latest message")
    }
}

private struct PressReporter: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { pressed = p }
            }
    }
}

private struct DiveLogo: View {
    let time: Double?
    private static let cycle = 2.6

    var body: some View {
        let (y, opacity, bob) = state
        PullYardLogoMark(progress: 1, size: 30)
            .offset(y: y + bob)
            .opacity(opacity)
            .frame(width: 44, height: 44)
    }

    private var state: (CGFloat, Double, CGFloat) {
        guard let time else { return (0, 1, 0) }
        let t = time.truncatingRemainder(dividingBy: Self.cycle)
        func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 4) }
        func easeIn(_ x: Double) -> Double { pow(x, 2.6) }
        func smooth(_ x: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(max(x, 0), 1)) }
        switch t {
        case ..<0.7:
            let p = easeOut(t / 0.7)
            return (CGFloat(-34 * (1 - p)), smooth(t / 0.45), 0)
        case ..<1.9:
            let local = (t - 0.7) / 1.2
            let envelope = sin(.pi * local)
            return (0, 1, CGFloat(sin(local * .pi * 2) * 1.4 * envelope))
        case ..<2.45:
            let p = easeIn((t - 1.9) / 0.55)
            return (CGFloat(34 * p), 1 - smooth((t - 2.05) / 0.4), 0)
        default:
            return (34, 0, 0)
        }
    }
}

private struct ChatViewportKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InitialBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content
        }
    }
}

struct ChatWelcome: View {
    let chat: ChatSession
    let folder: String
    @Environment(AppModel.self) private var app

    private var tab: ClaudeTab? { app.claude.tabs.first { $0.chat === chat } }

    private var recent: [ClaudeSessionInfo] {
        let root = ClaudeSessionParser.projectRoot(for: folder)
        let sid = chat.sessionId ?? ""
        return app.claude.projects.first { $0.path == root }?.sessions.filter { $0.id != sid && !AgentSessionPrefs.shared.isArchived($0) }.prefix(3).map { $0 } ?? []
    }

    private struct Suggestion: Hashable {
        let icon: String
        let title: String
        let prompt: String
    }

    private var suggestions: [Suggestion] {
        var out: [Suggestion] = []
        let git = tab?.git
        if let git, !git.changes.isEmpty {
            out.append(Suggestion(icon: "eye", title: "Review my uncommitted changes", prompt: "Review my uncommitted changes (git diff HEAD). Point out bugs, risky parts and missing tests."))
            if let branch = git.branch, branch != "HEAD", git.repo != nil {
                out.append(Suggestion(icon: "arrow.triangle.pull", title: "Open a pull request", prompt: AgentShip.openPRPrompt(branch: branch, defaultBranch: nil, hasChanges: true, ahead: git.ahead)))
            }
        }
        if let tab, let pr = app.claude.pullRequest(for: tab) {
            out.append(Suggestion(icon: "text.bubble", title: "Address review on #\(pr.number)", prompt: "Read the review comments on pull request #\(pr.number) (\(pr.url)) with gh, fix what is valid and reply to what is not."))
        }
        out.append(Suggestion(icon: "map", title: "Explain the project structure", prompt: "Explain the project structure: main modules, how they connect, and where to start reading."))
        out.append(Suggestion(icon: "ladybug", title: "Find bugs in recent changes", prompt: "Look at the last few commits and find likely bugs or regressions."))
        out.append(Suggestion(icon: "checkmark.seal", title: "Write tests for changed code", prompt: "Write tests for the code changed on this branch, following the existing test style."))
        return Array(out.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                PullYardLogoMark(progress: 1, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text((folder as NSString).lastPathComponent).font(.syTitle2.weight(.semibold)).foregroundStyle(Color.syText)
                    HStack(spacing: 8) {
                        if let git = tab?.git, let branch = git.branch {
                            Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                            if !git.changes.isEmpty {
                                Text("· \(git.changes.count) changed").foregroundStyle(Color.syAmber)
                            }
                            if git.ahead > 0 {
                                Text("· \(git.ahead) unpushed")
                            }
                        } else {
                            Text(folder).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                }
            }
            Text("Describe a task. The agent reads the code, proposes changes and asks before acting.")
                .foregroundStyle(Color.syMuted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(suggestions, id: \.self) { s in
                    WelcomeSuggestionButton(icon: s.icon, title: s.title) { chat.send(s.prompt) }
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent in this project").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
                    ForEach(recent) { s in
                        Button {
                            app.claude.resume(s)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.syDim)
                                Text(AgentSessionPrefs.shared.title(s)).foregroundStyle(Color.syText).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Fmt.rel(s.modified)).font(.syCaption).foregroundStyle(Color.syDim)
                            }
                            .font(.syCallout)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text("/ commands · @ files · ⇧↩ new line · paste a screenshot ⌘V · ⌘K switch session")
                .font(.syCaption)
                .foregroundStyle(Color.syDim)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }
}

struct WelcomeSuggestionButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.syCallout)
                    .foregroundStyle(LinearGradient(colors: [BrandMark.violet, BrandMark.sky], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 18)
                Text(title).foregroundStyle(Color.syText).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .font(.syCallout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.syText.opacity(hover ? 0.07 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? BrandMark.violet.opacity(0.45) : Color.syLine))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.fade) { hover = h } }
    }
}

struct WorkingIndicator: View {
    let chat: ChatSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 8) {
                PullYardLoader(size: 26)
                Text(chat.status ?? (chat.pendingCount > 0 ? "Waiting for you" : "Working…"))
                    .foregroundStyle(Color.syMuted)
                if let start = chat.turnStartedAt {
                    Text("\(Int(ctx.date.timeIntervalSince(start)))s").font(.syCaption.monospacedDigit()).foregroundStyle(Color.syDim)
                }
                Spacer()
                Button("Stop") { chat.interrupt() }
                    .controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .font(.syCallout)
        }
    }
}

struct ErrorBanner: View {
    let text: String
    let retry: () -> Void
    var reconnect: (() -> Void)?
    @State private var waiting = false

    private var looksLikeAuth: Bool { ChatSession.isAuthError(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if looksLikeAuth {
                Label("Claude sign-in expired", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.syBody.weight(.semibold))
                    .foregroundStyle(Color.syAmber)
                Text(waiting ? "Finish signing in in Terminal. The session picks up where it stopped." : "Sign in again and the session resumes where it stopped.")
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                Text(text).font(.syCaption).foregroundStyle(Color.syDim).textSelection(.enabled).lineLimit(3)
            } else {
                Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.syAmber).textSelection(.enabled)
            }
            HStack {
                if looksLikeAuth {
                    Button {
                        waiting = true
                        ClaudeAccountStore.shared.reauthenticate {
                            waiting = false
                            (reconnect ?? retry)()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if waiting { WakeLoader() }
                            Text(waiting ? "Waiting for sign-in…" : "Sign in again")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.syAgentAccent)
                    .disabled(waiting)
                }
                Button("Restart session", action: reconnect ?? retry).controlSize(.small)
            }
        }
        .padding(12)
        .padding(.leading, 3)
        .background(Color.syRaised)
        .overlay(alignment: .leading) { Rectangle().fill(Color.syAmber).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatItemView: View {
    let item: ChatItem
    let chat: ChatSession
    let folder: String

    @Environment(AppModel.self) private var app

    private func edit(id: String, text: String) {
        guard !chat.busy, chat.sessionId?.isEmpty == false,
              let tab = app.claude.tabs.first(where: { $0.chat === chat }),
              let index = chat.items.firstIndex(where: { $0.id == id }) else {
            chat.draftRequest = text
            return
        }
        let later = chat.items[(index + 1)...].filter {
            if case .user(_, let t, _) = $0 { return t == text }
            return false
        }.count
        app.claude.rewind(tab, to: text, occurrenceFromEnd: later)
    }

    var body: some View {
        switch item {
        case .user(let id, let text, let images):
            UserBubble(text: text, images: images) { edit(id: id, text: text) }
        case .text(let t):
            AssistantText(text: t)
        case .thinking(let t):
            ThinkingView(text: t)
        case .tool(let call):
            ToolCallView(call: call, chat: chat, folder: folder)
        case .notice(_, let text, let isError):
            if text == "Interrupted" {
                HStack(spacing: 5) {
                    Image(systemName: "stop.circle")
                    Text("Interrupted")
                }
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.syText.opacity(0.06)))
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                HStack(spacing: 6) {
                    Rectangle().fill(Color.syLine).frame(height: 1)
                    Text(text).font(.syCaption).foregroundStyle(isError ? Color.syRed : Color.syDim).fixedSize()
                    Rectangle().fill(Color.syLine).frame(height: 1)
                }
            }
        }
    }
}

struct UserBubble: View {
    let text: String
    let images: [ChatImage]
    var onEdit: (() -> Void)?
    @State private var expanded = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 8) {
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(images) { img in
                                if let ns = img.image {
                                    Image(nsImage: ns).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }
                    if !text.isEmpty {
                        Text(text)
                            .foregroundStyle(Color.syText)
                            .textSelection(.enabled)
                            .lineLimit(expanded ? nil : 12)
                            .fixedSize(horizontal: false, vertical: true)
                        if text.split(separator: "\n").count > 12 {
                            Button(expanded ? "Collapse" : "Show all") { withAnimation(Motion.quick) { expanded.toggle() } }
                                .buttonStyle(.link)
                                .font(.syCaption)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.syAgentAccent.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.syAgentAccent.opacity(0.22)))
            }
            MessageActions(visible: hover && !text.isEmpty) {
                MessageActionButton(icon: "doc.on.doc", help: "Copy") { copyToPasteboard(text) }
                if let onEdit {
                    MessageActionButton(icon: "arrow.uturn.backward.circle", help: "Edit from here — continues in a new branch of this session") { onEdit() }
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(LingeringHover(hover: $hover))
    }
}

struct LingeringHover: ViewModifier {
    @Binding var hover: Bool
    @State private var hide: DispatchWorkItem?

    func body(content: Content) -> some View {
        content.onHover { inside in
            hide?.cancel()
            if inside {
                withAnimation(Motion.fade) { hover = true }
            } else {
                let item = DispatchWorkItem { withAnimation(Motion.fade) { hover = false } }
                hide = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
            }
        }
    }
}

struct MessageActions<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .opacity(visible ? 1 : 0)
            .offset(y: visible || Motion.reduced ? 0 : -3)
            .frame(height: 22)
    }
}

struct MessageActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var done = false
    @State private var hover = false

    var body: some View {
        Button {
            action()
            withAnimation(Motion.quick) { done = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation(Motion.fade) { done = false } }
        } label: {
            Image(systemName: done && icon == "doc.on.doc" ? "checkmark" : icon)
                .font(.syCaption)
                .foregroundStyle(hover ? Color.syText : Color.syMuted)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.syText.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct AssistantText: View {
    let text: ChatText
    @State private var hover = false

    var body: some View {
        if !text.text.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: text.text, streaming: !text.finalized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if text.finalized {
                    MessageActions(visible: hover) {
                        MessageActionButton(icon: "doc.on.doc", help: "Copy") { copyToPasteboard(text.text) }
                    }
                }
            }
            .contentShape(Rectangle())
            .modifier(LingeringHover(hover: $hover))
        }
    }
}

struct ThinkingView: View {
    let text: ChatText
    @State private var open = false

    var body: some View {
        if !text.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(Motion.quick) { open.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.syCaption2).rotationEffect(.degrees(open ? 90 : 0))
                        Image(systemName: "brain").foregroundStyle(Color.syViolet.opacity(0.8))
                        Text("Thinking")
                    }
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                }
                .buttonStyle(.plain)
                if open {
                    Text(text.text).font(.syCallout).foregroundStyle(Color.syMuted).textSelection(.enabled).padding(.leading, 18)
                        .transition(.reveal)
                }
            }
        }
    }
}

enum ToolPresentation {
    static func icon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "square.and.pencil"
        case "Bash": return "terminal"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "WebFetch": return "globe"
        case "WebSearch": return "magnifyingglass.circle"
        case "Task", "Agent": return "person.2"
        case "TodoWrite": return "checklist"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.clipboard"
        case "NotebookEdit": return "book"
        case "Skill": return "wand.and.stars"
        default: return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func title(_ call: ChatToolCall) -> String {
        if call.name.hasPrefix("mcp__") {
            let parts = call.name.split(separator: "_").filter { !$0.isEmpty }
            return parts.last.map(String.init) ?? call.name
        }
        return call.name
    }

    static func diffStat(_ call: ChatToolCall) -> DiffStat? {
        if let patch = call.structured?["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            let lines = patch.flatMap { $0["lines"] as? [String] ?? [] }
            return DiffStat(additions: lines.filter { $0.hasPrefix("+") }.count, deletions: lines.filter { $0.hasPrefix("-") }.count)
        }
        if call.name == "Write", let content = call.string("content") {
            return DiffStat(additions: content.split(separator: "\n", omittingEmptySubsequences: false).count, deletions: 0)
        }
        return nil
    }

    static func relative(_ path: String, _ folder: String) -> String {
        path.hasPrefix(folder + "/") ? String(path.dropFirst(folder.count + 1)) : path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    static func summary(_ call: ChatToolCall, folder: String) -> String {
        let i = call.input
        switch call.name {
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            return relative(i["file_path"] as? String ?? i["notebook_path"] as? String ?? "", folder)
        case "Bash": return i["description"] as? String ?? i["command"] as? String ?? ""
        case "Grep": return "\"\(i["pattern"] as? String ?? "")\"" + ((i["path"] as? String).map { " · " + relative($0, folder) } ?? "")
        case "Glob": return i["pattern"] as? String ?? ""
        case "WebFetch": return i["url"] as? String ?? ""
        case "WebSearch": return i["query"] as? String ?? ""
        case "Task", "Agent": return i["description"] as? String ?? ""
        case "Skill": return i["skill"] as? String ?? ""
        default:
            if let s = i.values.first(where: { $0 is String }) as? String { return String(s.prefix(120)) }
            return call.partialInput.isEmpty ? "" : "…"
        }
    }
}

struct ToolCallView: View {
    let call: ChatToolCall
    let chat: ChatSession
    let folder: String
    @State private var open: Bool?

    private var defaultOpen: Bool {
        if call.permission?.resolved == false { return true }
        switch call.name {
        case "Edit", "MultiEdit", "Write", "ExitPlanMode", "TodoWrite": return true
        default: return false
        }
    }

    var body: some View {
        let isOpen = open ?? defaultOpen
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Motion.quick) { open = !isOpen } } label: {
                HStack(spacing: 8) {
                    statusIcon
                    Image(systemName: ToolPresentation.icon(call.name)).foregroundStyle(Color.syMuted).frame(width: 16)
                    Text(ToolPresentation.title(call)).fontWeight(.semibold).foregroundStyle(Color.syText)
                    Text(ToolPresentation.summary(call, folder: folder))
                        .foregroundStyle(Color.syMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let stat = ToolPresentation.diffStat(call) { stat }
                    Image(systemName: "chevron.down").font(.syCaption2).foregroundStyle(Color.syDim).rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .font(.syCallout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Rectangle().fill(Color.syLine).frame(height: 1)
                ToolDetails(call: call, folder: folder)
                    .padding(10)
                    .transition(.reveal)
            }
            if let p = call.permission, !p.resolved {
                PermissionCard(request: p, chat: chat, folder: folder)
                    .padding(10)
                    .transition(.pop)
            }
        }
        .clipped()
        .animation(Motion.spring, value: call.permission?.resolved)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(borderColor, lineWidth: call.permission?.resolved == false ? 1.5 : 1))
    }

    private var borderColor: Color {
        if call.permission?.resolved == false { return .clear }
        switch call.status {
        case .error: return Color.syRed.opacity(0.5)
        case .denied: return Color.syAmber.opacity(0.5)
        default: return .clear
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch call.status {
        case .running:
            if call.permission?.resolved == false {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.syAmber)
            } else {
                WakeLoader()
            }
        case .done: Image(systemName: "checkmark").foregroundStyle(Color.syDim)
        case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syRed)
        case .denied: Image(systemName: "nosign").foregroundStyle(Color.syAmber)
        }
    }

}

struct ToolDetails: View {
    let call: ChatToolCall
    let folder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch call.name {
            case "Edit", "MultiEdit", "Write":
                if let path = call.string("file_path") {
                    HStack {
                        Text(ToolPresentation.relative(path, folder)).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
                        Spacer()
                        Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            .buttonStyle(.link).font(.syCaption)
                    }
                }
                InlineDiff(lines: diffLines)
            case "Bash":
                if let cmd = call.string("command") {
                    Text("$ " + cmd).font(.sy(size: 12, design: .monospaced)).foregroundStyle(Color.syText).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: 8, fill: .sySunken)
                }
                outputView(bashOutput)
            case "TodoWrite":
                TodoListView(todos: call.input["todos"] as? [[String: Any]] ?? [])
            case "ExitPlanMode":
                MarkdownView(text: call.string("plan") ?? "")
            case "AskUserQuestion":
                ForEach(Array((call.input["questions"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, q in
                    Text(q["question"] as? String ?? "").font(.syCallout.weight(.medium))
                }
                if let r = call.resultText { Text(r).font(.syCallout).foregroundStyle(Color.syMuted).textSelection(.enabled) }
            case "Read":
                if let content = (call.structured?["file"] as? [String: Any])?["content"] as? String {
                    outputView(content)
                } else {
                    outputView(call.resultText)
                }
            default:
                if !call.input.isEmpty, let data = try? JSONSerialization.data(withJSONObject: call.input, options: [.prettyPrinted, .sortedKeys]) {
                    outputView(String(decoding: data, as: UTF8.self), title: "Input")
                }
                outputView(call.resultText, title: "Result")
            }
        }
    }

    private var bashOutput: String? {
        if let s = call.structured {
            let out = (s["stdout"] as? String ?? "") + ((s["stderr"] as? String).flatMap { $0.isEmpty ? nil : "\n" + $0 } ?? "")
            return out.isEmpty ? call.resultText : out
        }
        return call.resultText
    }

    @ViewBuilder
    private func outputView(_ text: String?, title: String? = nil) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title).font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted) }
                ScrollView([.vertical, .horizontal]) {
                    Text(String(text.prefix(20_000)))
                        .font(.sy(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .card(radius: 8, fill: .sySunken)
            }
        }
    }

    private var diffLines: [DiffLine] {
        if let patch = call.structured?["structuredPatch"] as? [[String: Any]], !patch.isEmpty {
            var out: [DiffLine] = []
            var idx = 0
            for hunk in patch {
                var old = hunk["oldStart"] as? Int ?? 1, new = hunk["newStart"] as? Int ?? 1
                for l in hunk["lines"] as? [String] ?? [] {
                    let body = String(l.dropFirst())
                    switch l.first {
                    case "+": out.append(DiffLine(id: idx, kind: .add, text: body, oldLine: nil, newLine: new)); new += 1
                    case "-": out.append(DiffLine(id: idx, kind: .del, text: body, oldLine: old, newLine: nil)); old += 1
                    default: out.append(DiffLine(id: idx, kind: .context, text: body, oldLine: old, newLine: new)); old += 1; new += 1
                    }
                    idx += 1
                }
            }
            return out
        }
        var out: [DiffLine] = []
        var idx = 0
        if call.name == "Write" {
            for (n, l) in (call.string("content") ?? "").components(separatedBy: "\n").enumerated() {
                out.append(DiffLine(id: idx, kind: .add, text: l, oldLine: nil, newLine: n + 1)); idx += 1
            }
            return out
        }
        let edits: [[String: Any]] = call.name == "MultiEdit" ? (call.input["edits"] as? [[String: Any]] ?? []) : [call.input]
        for e in edits {
            for l in (e["old_string"] as? String ?? "").components(separatedBy: "\n") {
                out.append(DiffLine(id: idx, kind: .del, text: l, oldLine: nil, newLine: nil)); idx += 1
            }
            for l in (e["new_string"] as? String ?? "").components(separatedBy: "\n") {
                out.append(DiffLine(id: idx, kind: .add, text: l, oldLine: nil, newLine: nil)); idx += 1
            }
        }
        return out
    }
}

struct InlineDiff: View {
    let lines: [DiffLine]
    @State private var showAll = false

    var body: some View {
        let shown = showAll ? lines : Array(lines.prefix(60))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { DiffLineView(line: $0).equatable() }
            if lines.count > 60 && !showAll {
                Button("Show \(lines.count - 60) more lines") { withAnimation(Motion.quick) { showAll = true } }
                    .buttonStyle(.link).font(.syCaption).padding(6)
            }
        }
        .background(Color.sySunken)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct TodoListView: View {
    let todos: [[String: Any]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                let status = todo["status"] as? String ?? "pending"
                HStack(spacing: 8) {
                    Image(systemName: status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(status == "completed" ? Color.syMuted : status == "in_progress" ? Color.syText : Color.syDim)
                    Text(todo["content"] as? String ?? todo["subject"] as? String ?? "")
                        .strikethrough(status == "completed")
                        .foregroundStyle(status == "completed" ? Color.syMuted : Color.syText)
                }
                .font(.syCallout)
            }
        }
    }
}

struct PermissionCard: View {
    let request: PermissionRequest
    let chat: ChatSession
    let folder: String
    @State private var feedback = ""
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch request.toolName {
            case "AskUserQuestion":
                questionView
            case "ExitPlanMode":
                Text("Claude has a plan. Start implementing?").font(.syCallout.weight(.semibold))
                HStack {
                    Button("Yes, auto-accept edits") {
                        chat.respond(request, allow: true)
                        chat.setPermissionMode("acceptEdits")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Yes, ask before edits") {
                        chat.respond(request, allow: true)
                        chat.setPermissionMode("default")
                    }
                    Spacer()
                }
                denyRow(placeholder: "What to change in the plan…")
            default:
                Text(question).font(.syCaption).foregroundStyle(Color.syAmber)
                if let d = request.description, !d.isEmpty { Text(d).font(.syCallout).foregroundStyle(Color.syMuted) }
                if let path = request.blockedPath {
                    Text(ToolPresentation.relative(path, folder)).font(.syCaption.monospaced()).foregroundStyle(Color.syMuted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Allow") { chat.respond(request, allow: true) }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: [.command])
                        Spacer()
                        Text("⌘↩").font(.syCaption).foregroundStyle(Color.syDim)
                    }
                    ForEach(Array(request.suggestions.enumerated()), id: \.offset) { _, s in
                        Button { chat.respond(request, allow: true, always: s) } label: {
                            Text("Allow, and don't ask again for " + s.label)
                                .lineLimit(1)
                        }
                        .buttonStyle(.link)
                    }
                }
                denyRow(placeholder: "No — tell Claude what to do instead…")
            }
        }
        .padding(12)
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.syRaised)
        .overlay(alignment: .leading) { Rectangle().fill(Color.syAmber).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var question: String {
        switch request.toolName {
        case "Bash": return "Claude wants to run a command"
        case "Edit", "MultiEdit": return "Claude wants to edit a file"
        case "Write": return "Claude wants to write a file"
        case "WebFetch": return "Claude wants to fetch a URL"
        default: return "Claude wants to use \(request.toolName)"
        }
    }

    private func denyRow(placeholder: String) -> some View {
        HStack {
            TextField(placeholder, text: $feedback)
                .textFieldStyle(.roundedBorder)
                .onSubmit { chat.respond(request, allow: false, message: feedback) }
            Button("Deny") { chat.respond(request, allow: false, message: feedback) }
        }
    }

    @ViewBuilder
    private var questionView: some View {
        let questions = request.input["questions"] as? [[String: Any]] ?? []
        ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
            let text = q["question"] as? String ?? ""
            let options = q["options"] as? [[String: Any]] ?? []
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.syCallout.weight(.semibold))
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    let label = o["label"] as? String ?? ""
                    Button {
                        answers[text] = label
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: answers[text] == label ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(answers[text] == label ? Color.syAccent : Color.syDim)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(label)
                                if let d = o["description"] as? String { Text(d).font(.syCaption).foregroundStyle(Color.syMuted) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("Other…", text: Binding(get: { options.contains { $0["label"] as? String == answers[text] } ? "" : (answers[text] ?? "") }, set: { answers[text] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
        HStack {
            Button("Submit") {
                var input = request.input
                input["answers"] = answers
                chat.respond(request, allow: true, updatedInput: input)
            }
            .buttonStyle(.borderedProminent)
            .disabled(answers.count < questions.count)
            Button("Skip") { chat.respond(request, allow: false, message: "The user skipped the question") }
        }
    }
}
