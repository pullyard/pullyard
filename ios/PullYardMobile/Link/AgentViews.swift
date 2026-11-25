import AVFoundation
import SwiftUI

struct MacLinkSection: View {
    @ObservedObject private var link = LinkClient.shared
    @State private var scanning = false
    @State private var pairingError: String?
    @State private var manualHost = ""
    @State private var confirmUnpair = false

    var body: some View {
        Section {
            if let mac = link.mac {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(MobileTheme.accent).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mac.name).mobileFont(size: 16, weight: .semibold)
                        Text(statusText).mobileFont(size: 12).foregroundStyle(statusColor)
                    }
                    Spacer()
                    if case .connecting = link.status { PullYardLoader(size: 26) }
                }
                if mac.iroh == nil {
                    Text("Pair again with the latest PullYard on your Mac to connect from anywhere, not only on the same Wi‑Fi.")
                        .mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                }
                if !link.isConnected {
                    Button { link.connectIfNeeded() } label: { Label("Connect", systemImage: "bolt.horizontal.circle") }
                }
                NavigationLink(value: Route.agents) { Label("Agent sessions", systemImage: "bubble.left.and.text.bubble.right") }
                HStack {
                    TextField("Address for VPN / Tailscale (host:port)", text: $manualHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { link.setManualHost(manualHost) }
                    if manualHost != (mac.manualHost ?? "") {
                        Button("Save") { link.setManualHost(manualHost) }
                    }
                }
                .onAppear { manualHost = mac.manualHost ?? "" }
                Button(role: .destructive) { confirmUnpair = true } label: { Label("Unpair Mac", systemImage: "xmark.circle") }
            } else {
                Button { scanning = true } label: { Label("Pair with PullYard on Mac", systemImage: "qrcode.viewfinder") }
            }
            if let pairingError {
                Text(pairingError).mobileFont(size: 13).foregroundStyle(MobileTheme.red)
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("On the Mac open PullYard → Settings → iPhone → Show pairing code. Your iPhone can then start agent fixes on the Mac and follow the chat. The connection is end-to-end encrypted.")
        }
        .pyRow()
        .sheet(isPresented: $scanning) {
            PairingScanner { code in
                scanning = false
                guard let pairing = PYLinkPairing.parse(code) else { pairingError = "That isn't a PullYard pairing code."; return }
                Task { await pair(pairing) }
            }
            .pySheetStyle()
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { link.unpair() }
            Button("Cancel", role: .cancel) {}
        }
        .onReceive(NotificationCenter.default.publisher(for: .pullyardPairing)) { note in
            if let pairing = note.object as? PYLinkPairing { Task { await pair(pairing) } }
        }
    }

    private func pair(_ pairing: PYLinkPairing) async {
        pairingError = nil
        do { try await link.pair(pairing) } catch { pairingError = error.localizedDescription }
    }

    private var statusText: String {
        switch link.status {
        case .connected: return link.viaInternet ? L("Connected over the internet") : L("Connected on this network")
        case .connecting: return L("Connecting…")
        case .offline: return L("Not connected")
        case let .failed(reason): return reason
        case .unpaired: return ""
        }
    }

    private var statusColor: Color {
        switch link.status {
        case .connected: MobileTheme.green
        case .failed: MobileTheme.amberInk
        default: MobileTheme.muted
        }
    }
}

extension Notification.Name {
    static let pullyardPairing = Notification.Name("PullYardPairing")
}

struct PairingScanner: View {
    let found: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                QRScannerView(found: found)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(MobileTheme.accent, lineWidth: 2))
                Text("Point the camera at the code in PullYard on your Mac (Settings → iPhone).")
                    .mobileFont(size: 14).foregroundStyle(MobileTheme.muted).multilineTextAlignment(.center)
                HStack {
                    TextField("…or paste the pairing link", text: $pasted).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Pair") { found(pasted) }.disabled(pasted.isEmpty)
                }
                .padding(12)
                .background(MobileTheme.card, in: Capsule())
                Spacer()
            }
            .padding(18)
            .background(BrandBackdrop())
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var delivered = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            view.layer.sublayers?.first?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, value.hasPrefix("pullyard://pair") else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            found?(value)
        }
    }
}

struct FixWithAgentMenu: View {
    let key: PRKey
    let hasConflicts: Bool
    @ObservedObject private var link = LinkClient.shared
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var starting = false
    @State private var showPairing = false
    @State private var customTask = false
    @State private var customText = ""

    var body: some View {
        Menu {
            Button { start("comments") } label: { Label("Fix review comments", systemImage: "text.bubble") }
            if hasConflicts { Button { start("conflicts") } label: { Label("Resolve conflicts", systemImage: "arrow.triangle.merge") } }
            Button { customTask = true } label: { Label("Custom task…", systemImage: "pencil") }
            let existing = link.sessions.filter { $0.repo?.caseInsensitiveCompare(key.repo) == .orderedSame && $0.number == key.number }
            if !existing.isEmpty {
                Section("On \(link.macName)") {
                    ForEach(existing) { session in
                        Button { router.open(.agent(session.id), in: model.selectedTab) } label: { Label(session.title, systemImage: "bubble.left.and.text.bubble.right") }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if starting { PullYardLoader(size: 26, style: .monochrome(.white)) } else { Image(systemName: "wand.and.stars") }
                Text(starting ? "Starting on \(link.macName)…" : "Fix with agent")
            }
            .mobileFont(size: 15, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Capsule())
            .pyGlass(in: Capsule(), tint: MobileTheme.coral, interactive: true, fallback: MobileTheme.coral)
        }
        .disabled(starting)
        .sheet(isPresented: $showPairing) {
            NavigationStack {
                List { MacLinkSection() }
                    .pyListStyle()
                    .routeDestinations()
                    .navigationTitle("Connect your Mac")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPairing = false } } }
            }
            .pySheetStyle()
        }
        .alert("Task for the agent", isPresented: $customTask) {
            TextField("What should the agent do?", text: $customText)
            Button("Start") { start("custom", text: customText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func start(_ kind: String, text: String? = nil) {
        guard link.mac != nil else { showPairing = true; return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let session = try await link.startFix(repo: key.repo, number: key.number, kind: kind, text: text)
                router.open(.agent(session), in: model.selectedTab)
            } catch {
                feedback.error(error, key: "agent-start")
            }
        }
    }
}

struct AgentSessionsView: View {
    @ObservedObject private var link = LinkClient.shared
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var loading = false
    @State private var resuming: String?
    @State private var query = ""

    private var closed: [PYLinkSession] {
        link.history.filter { $0.state == "closed" && matches($0) }
    }

    private var open: [PYLinkSession] {
        link.sessions.filter(matches)
    }

    private func matches(_ session: PYLinkSession) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let number = q.hasPrefix("#") ? String(q.dropFirst()) : q
        return session.title.localizedCaseInsensitiveContains(q)
            || session.folder.localizedCaseInsensitiveContains(q)
            || (session.repo ?? "").localizedCaseInsensitiveContains(q)
            || session.number.map { String($0) == number } == true
    }

    var body: some View {
        List {
            if link.sessions.isEmpty, link.history.isEmpty, link.status == .connecting || loading {
                VStack(spacing: 12) {
                    PullYardLoader(size: 34)
                    Text("Connecting to \(link.macName)…").mobileFont(size: 14).foregroundStyle(MobileTheme.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 50)
                .listRowBackground(Color.clear)
            } else if link.sessions.isEmpty, link.history.isEmpty {
                PYEmptyState(title: link.isConnected ? "No agent sessions" : "Not connected", message: link.isConnected ? "Start one with Fix with agent on a pull request." : "Open PullYard on your Mac and turn on iPhone access in its Settings.")
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
            } else {
                if !open.isEmpty {
                    Section("Open on \(link.macName)") {
                        ForEach(open) { session in
                            NavigationLink(value: Route.agent(session.id)) { row(session) }
                                .pyRow()
                        }
                    }
                }
                if !closed.isEmpty {
                    Section {
                        ForEach(closed) { session in
                            Button { resume(session) } label: {
                                HStack {
                                    row(session)
                                    Spacer(minLength: 8)
                                    if resuming == session.id { PullYardLoader(size: 22) } else { Image(systemName: "arrow.uturn.forward.circle").foregroundStyle(MobileTheme.accent) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.pyPlain)
                            .disabled(resuming != nil)
                            .pyRow()
                        }
                    } header: {
                        Text("History")
                    } footer: {
                        Text("Tap a session to continue it in PullYard on \(link.macName).")
                    }
                } else if loading, !link.sessions.isEmpty {
                    HStack { Spacer(); PullYardLoader(size: 26); Spacer() }.listRowBackground(Color.clear)
                }
            }
        }
        .pyListStyle()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions, projects or #PR")
        .refreshable { await load() }
        .navigationTitle("Agents")
        .task { await load() }
    }

    private func load() async {
        loading = true
        await link.refreshSessions()
        await link.loadHistory()
        loading = false
    }

    private func resume(_ session: PYLinkSession) {
        resuming = session.id
        Task {
            defer { resuming = nil }
            do {
                let tab = try await link.resume(session.id)
                router.open(.agent(tab), in: model.selectedTab)
            } catch {
                feedback.error(error, key: "agent-resume")
            }
        }
    }

    private func row(_ session: PYLinkSession) -> some View {
        HStack(spacing: 10) {
            AgentStateDot(state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).mobileFont(size: 15, weight: .semibold).lineLimit(2).foregroundStyle(MobileTheme.ink)
                Text(subtitle(session)).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1)
            }
        }
    }

    private func subtitle(_ session: PYLinkSession) -> String {
        let place: String
        if let repo = session.repo {
            place = session.number.map { "\(repo) #\($0)" } ?? repo
        } else {
            place = (session.folder as NSString).lastPathComponent
        }
        guard let updated = session.updated else { return place }
        return "\(place) · \(updated.formatted(.relative(presentation: .named)))"
    }
}

struct AgentChatView: View {
    let session: String
    @ObservedObject private var link = LinkClient.shared
    @State private var draft = ""
    @State private var busySince: Date?
    @State private var atBottom = true
    @State private var unseen = false
    @State private var settled = false
    @State private var followUntil = Date.distantPast
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollRequest = 0
    @FocusState private var focused: Bool

    private var chat: AgentChat? { link.chats[session] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let chat {
                        ForEach(chat.items) { item in AgentItemView(item: item).id(item.id) }
                        ForEach(chat.state.pending) { permission in
                            PermissionCard(permission: permission) { allow, always in
                                link.respond(permission, allow: allow, always: always, in: session)
                            }
                            .id("perm-\(permission.id)")
                        }
                        if chat.state.busy {
                            AgentWorkingCapsule(status: chat.state.status, since: busySince)
                                .id("busy")
                        }
                        if let error = chat.state.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").mobileFont(size: 13).foregroundStyle(MobileTheme.amberInk)
                        }
                    } else {
                        PullYardLoader(title: link.isConnected ? "Loading the chat…" : "Connecting to your Mac…", size: 64)
                            .frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("agentChat")).minY } action: { minY in
                            trackBottom(minY)
                        }
                }
                .padding(16)
            }
            .coordinateSpace(.named("agentChat"))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                let follow = atBottom && viewportHeight > 0 && height != viewportHeight
                viewportHeight = height
                if follow { scrollToEnd(proxy, animated: false) }
            }
            .background(BrandBackdrop())
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if settled && !atBottom {
                    JumpToLatestButton(unseen: unseen) { scrollToEnd(proxy, animated: true) }
                        .padding(.bottom, 12)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: settled && !atBottom)
            .onChange(of: contentSignature) { _, _ in
                if !settled || atBottom || Date() < followUntil {
                    scrollToEnd(proxy, animated: false)
                } else {
                    unseen = true
                }
            }
            .onChange(of: scrollRequest) { _, _ in scrollToEnd(proxy, animated: true) }
            .onChange(of: chat?.state.busy, initial: true) { _, busy in busySince = busy == true ? (busySince ?? Date()) : nil }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onChange(of: focused) { _, on in
            guard on, atBottom else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrollRequest += 1 }
        }
        .navigationTitle(chat?.title ?? L("Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if chat?.state.busy == true {
                    Button { link.stop(session) } label: { Image(systemName: "stop.circle.fill").foregroundStyle(MobileTheme.red) }
                        .accessibilityLabel("Stop")
                }
            }
        }
        .task {
            link.connectIfNeeded()
            link.subscribe(session)
        }
        .onDisappear { link.unsubscribe(session) }
    }

    private var contentSignature: String {
        guard let chat else { return "none" }
        let last = chat.items.last
        return "\(chat.items.count)|\(last?.id ?? "")|\(last?.text.count ?? 0)|\(last?.status ?? "")|\(chat.state.pending.count)|\(chat.state.busy)|\(chat.state.error != nil)"
    }

    private func trackBottom(_ minY: CGFloat) {
        guard viewportHeight > 0 else { return }
        let bottom = minY <= viewportHeight + 48
        if !bottom, Date() < followUntil { return }
        if bottom != atBottom { atBottom = bottom }
        if bottom, unseen { unseen = false }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        followUntil = Date().addingTimeInterval(animated ? 0.6 : 0.15)
        atBottom = true
        unseen = false
        if animated {
            withAnimation(.snappy(duration: 0.4)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        DispatchQueue.main.async {
            guard !animated else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            if chat?.items.isEmpty == false { settled = true }
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message the agent", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .mobileFont(size: 16)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .pyGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fallback: MobileTheme.card)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                link.send(text, to: session)
                draft = ""
                scrollRequest += 1
            } label: {
                Image(systemName: "arrow.up").mobileFont(size: 17, weight: .bold).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .pyGlass(in: Circle(), tint: MobileTheme.accentFill, interactive: true, fallback: MobileTheme.accentFill)
            }
            .buttonStyle(.pyPlain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !link.isConnected)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

private struct JumpToLatestButton: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if unseen && !reduceMotion {
                    PhaseAnimator([false, true]) { expanded in
                        Circle()
                            .stroke(MobileTheme.accent.opacity(expanded ? 0 : 0.6), lineWidth: 2)
                            .frame(width: 42, height: 42)
                            .scaleEffect(expanded ? 1.5 : 1)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.2) : .linear(duration: 0.01)
                    }
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(unseen ? Color.white : MobileTheme.ink)
                    .phaseAnimator(reduceMotion ? [CGFloat(0)] : [0, 3, 0]) { content, offset in
                        content.offset(y: offset)
                    } animation: { _ in .easeInOut(duration: 0.7) }
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                    .pyGlass(in: Circle(), tint: unseen ? MobileTheme.accentFill : nil, interactive: true, fallback: unseen ? MobileTheme.accentFill : MobileTheme.card)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .frame(width: 64, height: 64)
            .contentShape(Circle())
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel("Scroll to the latest message")
    }
}

private struct AgentItemView: View {
    let item: PYLinkItem
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(item.text).mobileFont(size: 15).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(MobileTheme.accentFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
        case "text":
            MarkdownView(markdown: item.text)
        case "thinking":
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    ThinkingLabel(text: "Thinking").mobileFont(size: 12, weight: .semibold)
                    if expanded { Text(item.text).mobileFont(size: 13).foregroundStyle(MobileTheme.muted) }
                }
            }
            .buttonStyle(.pyPlain)
        case "tool":
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if item.status == "running" {
                            WakeLoader().frame(width: 18, height: 16)
                        } else {
                            Image(systemName: icon).foregroundStyle(color)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.tool ?? "Tool").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.ink)
                        if !item.text.isEmpty {
                            Text(item.text).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(expanded ? nil : 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.pyPlain)
        case "error":
            Label(item.text, systemImage: "exclamationmark.triangle.fill").mobileFont(size: 13).foregroundStyle(MobileTheme.red)
        default:
            Text(item.text).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
        }
    }

    private var icon: String {
        switch item.status {
        case "running": "gearshape.fill"
        case "error": "xmark.circle.fill"
        case "denied": "hand.raised.fill"
        default:
            switch item.tool {
            case "Bash": "terminal"
            case "Edit", "Write", "MultiEdit": "pencil"
            case "Read": "doc.text"
            case "Grep", "Glob": "magnifyingglass"
            case "TodoWrite": "checklist"
            default: "checkmark.circle"
            }
        }
    }

    private var color: Color {
        switch item.status {
        case "running": MobileTheme.amber
        case "error": MobileTheme.red
        case "denied": MobileTheme.slate
        default: MobileTheme.green
        }
    }
}

private struct PermissionCard: View {
    let permission: PYLinkPermission
    let respond: (Bool, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Permission needed · \(permission.tool)", systemImage: "hand.raised.fill").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.amberInk)
            Text(permission.summary).mobileFont(size: 14).foregroundStyle(MobileTheme.ink)
            if let detail = permission.detail {
                Text(detail).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 10))
            }
            PYGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    button("Allow", tint: MobileTheme.greenFill) { respond(true, false) }
                    button("Always", tint: MobileTheme.accentFill) { respond(true, true) }
                    button("Deny", tint: MobileTheme.redFill) { respond(false, false) }
                }
            }
        }
        .padding(14)
        .background(MobileTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sensoryFeedback(.warning, trigger: permission.id)
    }

    private func button(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L(title)).mobileFont(size: 14, weight: .semibold).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Capsule())
                .pyGlass(in: Capsule(), tint: tint, interactive: true, fallback: tint)
        }
        .buttonStyle(.pyPlain)
    }
}
