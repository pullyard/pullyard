import AVFoundation
import PhotosUI
import SwiftUI

struct MacLinkSection: View {
    @ObservedObject private var link = LinkClient.shared
    @State private var scanning = false
    @State private var pairingError: String?
    @State private var manualHost = ""
    @State private var confirmUnpair = false
    @AppStorage(AgentActivities.enabledKey) private var liveActivity = true

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
                Toggle(isOn: $liveActivity) { Label("Live Activity for agents", systemImage: "platter.filled.top.iphone") }
                    .onChange(of: liveActivity) { _, on in if !on { AgentActivities.endAll() } }
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
    let hasComments: Bool
    let hasConflicts: Bool
    @ObservedObject private var link = LinkClient.shared
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var starting = false
    @State private var showPairing = false
    @State private var customTask = false
    @State private var customText = ""
    @State private var review: PromptReview?
    @State private var launching = false

    var body: some View {
        Menu {
            if hasComments { Button { start("comments") } label: { Label("Fix review comments", systemImage: "text.bubble") } }
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
                if starting || launching { PullYardLoader(size: 26, style: .monochrome(.white)) } else { Image(systemName: "wand.and.stars") }
                Text(launching ? "Starting on \(link.macName)…" : starting ? "Preparing on \(link.macName)…" : "Fix with agent")
            }
            .mobileFont(size: 15, weight: .semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(Capsule())
            .pyGlass(in: Capsule(), tint: MobileTheme.coral, interactive: true, fallback: MobileTheme.coral)
        }
        .disabled(starting || launching)
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
        .sheet(item: $review) { item in
            PromptReviewSheet(review: item) { prompt in
                launch(item, prompt: prompt)
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
                let preview = try await link.previewFix(repo: key.repo, number: key.number, kind: kind, text: text)
                review = PromptReview(kind: kind, text: text, name: preview.name, prompt: preview.prompt)
            } catch {
                feedback.error(error, key: "agent-start")
            }
        }
    }

    private func launch(_ item: PromptReview, prompt: String) {
        review = nil
        launching = true
        Task {
            defer { launching = false }
            do {
                let edited = prompt == item.prompt ? nil : prompt
                let session = try await link.startFix(repo: key.repo, number: key.number, kind: item.kind, text: item.text, prompt: edited)
                router.open(.agent(session), in: model.selectedTab)
            } catch {
                feedback.error(error, key: "agent-start")
            }
        }
    }
}

struct PromptReview: Identifiable {
    let id = UUID()
    let kind: String
    let text: String?
    let name: String
    let prompt: String
}

private struct PromptReviewSheet: View {
    let review: PromptReview
    let start: (String) -> Void
    @State private var prompt: String
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var link = LinkClient.shared

    init(review: PromptReview, start: @escaping (String) -> Void) {
        self.review = review
        self.start = start
        _prompt = State(initialValue: review.prompt)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.name).mobileFont(size: 17, weight: .semibold, design: .serif).foregroundStyle(MobileTheme.ink).lineLimit(2)
                    Text(String(format: L("This is what the agent on %@ receives. You can change it before starting."), link.macName))
                        .mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                }
                Group {
                    if editing {
                        TextEditor(text: $prompt)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden)
                    } else {
                        ScrollView {
                            Text(prompt)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(MobileTheme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
                .frame(maxHeight: .infinity)
                .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(editing ? MobileTheme.accent.opacity(0.5) : MobileTheme.line))
                Button {
                    start(prompt)
                } label: {
                    Label("Start on \(link.macName)", systemImage: "wand.and.stars")
                        .mobileFont(size: 16, weight: .semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(Capsule())
                        .pyGlass(in: Capsule(), tint: MobileTheme.coral, interactive: true, fallback: MobileTheme.coral)
                }
                .buttonStyle(.pyPlain)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .background(BrandBackdrop())
            .navigationTitle("Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }
                        .fontWeight(.semibold)
                }
                if prompt != review.prompt {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Reset to original") { withAnimation(.snappy) { prompt = review.prompt } }
                    }
                }
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
    @State private var reordering = false
    @State private var closing: PYLinkSession?
    @AppStorage("agents.collapsedProjects") private var collapsedRaw = ""
    @AppStorage("agents.projectOrder") private var orderRaw = ""

    private struct ProjectGroup: Identifiable {
        let id: String
        var open: [PYLinkSession] = []
        var closed: [PYLinkSession] = []
        var latest = Date.distantPast

        var name: String { (id as NSString).lastPathComponent }
        var count: Int { open.count + closed.count }
        var working: Bool { open.contains { $0.state == "working" || $0.state == "waiting" } }
    }

    private var active: [PYLinkSession] {
        let rank = ["waiting": 0, "working": 1, "active": 2]
        return link.sessions
            .filter { rank[$0.state] != nil && matches($0) }
            .sorted { (rank[$0.state] ?? 3) < (rank[$1.state] ?? 3) }
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: "\n").map(String.init)) }
    private var order: [String] { orderRaw.split(separator: "\n").map(String.init) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func groups(filtered: Bool = true) -> [ProjectGroup] {
        var map: [String: ProjectGroup] = [:]
        let activeIDs = Set(active.map(\.id))
        for session in link.sessions where (!filtered || matches(session)) && !(filtered && activeIDs.contains(session.id)) {
            let root = Self.projectRoot(session.folder)
            map[root, default: ProjectGroup(id: root)].open.append(session)
            map[root]?.latest = .distantFuture
        }
        for session in link.history where session.state == "closed" && (!filtered || matches(session)) {
            let root = Self.projectRoot(session.folder)
            map[root, default: ProjectGroup(id: root)].closed.append(session)
            if let updated = session.updated, updated > (map[root]?.latest ?? .distantPast) { map[root]?.latest = updated }
        }
        let order = order
        return map.values.sorted { a, b in
            switch (order.firstIndex(of: a.id), order.firstIndex(of: b.id)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.latest == b.latest ? a.name < b.name : a.latest > b.latest
            }
        }
    }

    static func projectRoot(_ folder: String) -> String {
        if let range = folder.range(of: "/.claude/worktrees/") { return String(folder[..<range.lowerBound]) }
        let parent = (folder as NSString).deletingLastPathComponent
        if parent.hasSuffix("-worktrees") { return String(parent.dropLast("-worktrees".count)) }
        return folder
    }

    private func toggle(_ project: String) {
        var set = collapsed
        if set.contains(project) { set.remove(project) } else { set.insert(project) }
        withAnimation(.snappy) { collapsedRaw = set.sorted().joined(separator: "\n") }
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
                if !active.isEmpty {
                    Section {
                        ForEach(active) { session in
                            NavigationLink(value: Route.agent(session.id)) { row(session, showProject: true) }
                                .pyRow()
                                .modifier(CloseActions(session: session, closing: $closing))
                        }
                    } header: {
                        HStack(spacing: 8) {
                            Circle().fill(MobileTheme.green).frame(width: 7, height: 7)
                            Text("Active").mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink)
                            Text("\(active.count)")
                                .mobileFont(size: 11, weight: .semibold).monospacedDigit()
                                .foregroundStyle(MobileTheme.muted)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(MobileTheme.ink.opacity(0.07), in: Capsule())
                        }
                        .padding(.vertical, 6)
                        .textCase(nil)
                    }
                }
                ForEach(groups()) { group in
                    let isCollapsed = !searching && collapsed.contains(group.id)
                    Section {
                        if !isCollapsed {
                            ForEach(group.open) { session in
                                NavigationLink(value: Route.agent(session.id)) { row(session) }
                                    .pyRow()
                                    .modifier(CloseActions(session: session, closing: $closing))
                            }
                            ForEach(group.closed) { session in
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
                        }
                    } header: {
                        projectHeader(group, collapsed: isCollapsed)
                    }
                }
                if loading, link.history.isEmpty, !link.sessions.isEmpty {
                    HStack { Spacer(); PullYardLoader(size: 26); Spacer() }.listRowBackground(Color.clear)
                }
            }
        }
        .pyListStyle()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search sessions, projects or #PR")
        .refreshable { await load() }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { reordering = true } label: { Label("Reorder projects", systemImage: "arrow.up.arrow.down") }
                    Button { withAnimation(.snappy) { collapsedRaw = groups(filtered: false).map(\.id).joined(separator: "\n") } } label: { Label("Collapse all", systemImage: "rectangle.compress.vertical") }
                    Button { withAnimation(.snappy) { collapsedRaw = "" } } label: { Label("Expand all", systemImage: "rectangle.expand.vertical") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(link.sessions.isEmpty && link.history.isEmpty)
            }
        }
        .confirmationDialog("Close this session?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible, presenting: closing) { session in
            Button("Close session", role: .destructive) { close(session) }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(session.state == "working" || session.state == "waiting" ? "The agent is working. Closing stops it and closes the tab on your Mac. You can continue it later from History." : "This closes the tab on your Mac. You can continue it later from History.")
        }
        .sheet(isPresented: $reordering) {
            ProjectOrderSheet(projects: groups(filtered: false).map { ($0.id, $0.name) }) { ids in
                orderRaw = ids.joined(separator: "\n")
            }
            .pySheetStyle()
        }
        .task { await load() }
    }

    private func projectHeader(_ group: ProjectGroup, collapsed: Bool) -> some View {
        Button { toggle(group.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(MobileTheme.accent)
                Text(group.name).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                Text("\(group.count)")
                    .mobileFont(size: 11, weight: .semibold).monospacedDigit()
                    .foregroundStyle(MobileTheme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(MobileTheme.ink.opacity(0.07), in: Capsule())
                if group.working { AgentStateDot(state: "working") }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MobileTheme.muted)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pyPlain)
        .textCase(nil)
        .disabled(searching)
        .accessibilityLabel(group.name)
        .accessibilityValue(collapsed ? L("Collapsed") : L("Expanded"))
    }

    private func load() async {
        loading = true
        await link.refreshSessions()
        await link.loadHistory()
        loading = false
    }

    private func close(_ session: PYLinkSession) {
        closing = nil
        Task {
            do {
                try await link.close(session.id)
                await link.loadHistory()
            } catch {
                feedback.error(error, key: "agent-close")
            }
        }
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

    private func row(_ session: PYLinkSession, showProject: Bool = false) -> some View {
        HStack(spacing: 10) {
            AgentStateDot(state: session.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).mobileFont(size: 15, weight: .semibold).lineLimit(2).foregroundStyle(MobileTheme.ink)
                Text(showProject ? projectSubtitle(session) : subtitle(session)).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1)
            }
        }
    }

    private func projectSubtitle(_ session: PYLinkSession) -> String {
        let project = (Self.projectRoot(session.folder) as NSString).lastPathComponent
        let state: String
        switch session.state {
        case "working": state = L("Working")
        case "waiting": state = L("Needs you")
        default: state = L("Idle")
        }
        if let number = session.number { return "\(project) · #\(number) · \(state)" }
        return "\(project) · \(state)"
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

private struct CloseActions: ViewModifier {
    let session: PYLinkSession
    @Binding var closing: PYLinkSession?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { closing = session } label: { Label("Close", systemImage: "xmark") }
            }
            .contextMenu {
                Button(role: .destructive) { closing = session } label: { Label("Close session", systemImage: "xmark.circle") }
            }
    }
}

private struct ProjectOrderSheet: View {
    @State var items: [(id: String, name: String)]
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(projects: [(String, String)], save: @escaping ([String]) -> Void) {
        _items = State(initialValue: projects.map { (id: $0.0, name: $0.1) })
        self.save = save
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.id) { item in
                    Label(item.name, systemImage: "folder.fill")
                        .mobileFont(size: 15, weight: .medium)
                        .foregroundStyle(MobileTheme.ink)
                        .pyRow()
                }
                .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }
            }
            .pyListStyle()
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Reorder projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save(items.map(\.id))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
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
    @State private var userScrolling = false
    @State private var lastCount = 0
    @State private var confirmClose = false
    @State private var editingItem: PYLinkItem?
    @State private var outgoingID = "local-\(UUID().uuidString)"
    @Namespace private var flight
    @State private var draftBeforeEdit = ""
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var attachments: [AgentAttachment] = []
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var dropTargeted = false
    @EnvironmentObject private var feedback: FeedbackCenter
    @FocusState private var focused: Bool

    private var chat: AgentChat? { link.chats[session] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let chat {
                        ForEach(chat.items) { item in
                            AgentItemView(item: item, flight: flight, pending: isPending(item, in: chat), onEdit: editAction(item, in: chat))
                                .id(item.id)
                                .transition(.asymmetric(insertion: item.kind == "user" ? (item.id.hasPrefix("local-") ? .identity : .scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity)) : .opacity.combined(with: .offset(y: 16)), removal: .opacity))
                        }
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
            .modifier(ScrollInteraction(active: $userScrolling))
            .onChange(of: userScrolling) { _, scrolling in if scrolling { followUntil = .distantPast } }
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
                let count = chat?.items.count ?? 0
                let delta = count - lastCount
                lastCount = count
                if userScrolling {
                    if !atBottom { unseen = true }
                    return
                }
                if !settled || atBottom || Date() < followUntil {
                    scrollToEnd(proxy, animated: settled && delta > 0 && delta <= 3)
                } else {
                    unseen = true
                }
            }
            .onChange(of: scrollRequest) { _, _ in scrollToEnd(proxy, animated: true) }
            .onChange(of: chat?.state.busy, initial: true) { _, busy in busySince = busy == true ? (busySince ?? Date()) : nil }
            .onAppear { scrollToEnd(proxy, animated: false) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .overlay { AgentDropOverlay(active: dropTargeted) }
        .onDrop(of: [.image, .fileURL, .data], isTargeted: $dropTargeted) { providers in
            Task { await add(providers) }
            return true
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoSelection, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            Task {
                for item in items {
                    if let attachment = await AgentAttachmentLoader.photo(item) { append(attachment) }
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            for url in urls {
                do { append(try AgentAttachmentLoader.file(at: url)) } catch { feedback.error(error, key: "agent-attach") }
            }
        }
        .onChange(of: focused) { _, on in
            guard on, atBottom else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { scrollRequest += 1 }
        }
        .navigationTitle(chat?.title ?? L("Agent"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if chat?.state.busy == true {
                    Button { link.stop(session) } label: { Image(systemName: "stop.circle.fill").foregroundStyle(MobileTheme.red) }
                        .accessibilityLabel("Stop")
                }
                Menu {
                    Button(role: .destructive) { confirmClose = true } label: { Label("Close session", systemImage: "xmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(!link.isConnected)
            }
        }
        .confirmationDialog("Close this session?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close session", role: .destructive) { closeSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(chat?.state.busy == true ? "The agent is working. Closing stops it and closes the tab on your Mac. You can continue it later from History." : "This closes the tab on your Mac. You can continue it later from History.")
        }
        .task {
            link.connectIfNeeded()
            link.subscribe(session)
        }
        .onDisappear { link.unsubscribe(session) }
    }

    private func isPending(_ item: PYLinkItem, in chat: AgentChat) -> Bool {
        item.id.hasPrefix("local-") && !chat.aliases.values.contains(item.id)
    }

    private func editAction(_ item: PYLinkItem, in chat: AgentChat) -> (() -> Void)? {
        guard item.kind == "user", !item.text.isEmpty, !chat.state.busy, link.isConnected, chat.remoteID(item.id).hasPrefix("u") else { return nil }
        return {
            withAnimation(.snappy) {
                if editingItem == nil { draftBeforeEdit = draft }
                editingItem = item
                draft = item.text
                attachments = []
            }
            focused = true
        }
    }

    private func cancelEdit() {
        withAnimation(.snappy) {
            editingItem = nil
            draft = draftBeforeEdit
            draftBeforeEdit = ""
        }
    }

    private func submitEdit(_ item: PYLinkItem) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text != item.text else { cancelEdit(); return }
        withAnimation(.snappy) {
            editingItem = nil
            draft = draftBeforeEdit
            draftBeforeEdit = ""
        }
        focused = false
        let session = session
        Task {
            do {
                let next = try await link.edit(item, text: text, in: session)
                router.replaceTop(with: .agent(next), in: model.selectedTab)
            } catch {
                feedback.error(error, key: "agent-edit")
            }
        }
    }

    private func closeSession() {
        let link = link
        let feedback = feedback
        let session = session
        dismiss()
        Task {
            do { try await link.close(session) } catch { feedback.error(error, key: "agent-close") }
        }
    }

    private var contentSignature: String {
        guard let chat else { return "none" }
        let last = chat.items.last
        return "\(chat.items.count)|\(last?.id ?? "")|\(last?.text.count ?? 0)|\(last?.status ?? "")|\(chat.state.pending.count)|\(chat.state.busy)|\(chat.state.error != nil)"
    }

    private func trackBottom(_ minY: CGFloat) {
        guard viewportHeight > 0 else { return }
        let bottom = minY <= viewportHeight + 48
        if !bottom, Date() < followUntil, !userScrolling { return }
        if bottom != atBottom { atBottom = bottom }
        if bottom, unseen { unseen = false }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        followUntil = Date().addingTimeInterval(animated ? 0.5 : 0.15)
        atBottom = true
        unseen = false
        if animated {
            withAnimation(.smooth(duration: 0.38)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                guard !userScrolling, atBottom else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var canSend: Bool {
        link.isConnected && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editingItem == nil && !attachments.isEmpty))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let editingItem {
                HStack(spacing: 10) {
                    Capsule().fill(MobileTheme.accent).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Edit message").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.accent)
                        Text(editingItem.text).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button(action: cancelEdit) {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(MobileTheme.muted)
                            .frame(width: 32, height: 32).contentShape(Circle())
                    }
                    .buttonStyle(.pyPlain)
                    .accessibilityLabel("Cancel editing")
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !attachments.isEmpty {
                AgentAttachmentStrip(attachments: attachments) { item in attachments.removeAll { $0.id == item.id } }
                    .padding(.horizontal, 10).padding(.top, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 6) {
                if editingItem == nil {
                Menu {
                    Button { showPhotos = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MobileTheme.muted)
                        .frame(width: 36, height: 36)
                        .background(MobileTheme.ink.opacity(0.06), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Attach")
                } else {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(MobileTheme.accent)
                        .frame(width: 44, height: 44)
                }
                TextField("Message the agent", text: $draft, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...5)
                    .mobileFont(size: 16)
                    .padding(.vertical, 11)
                    .background(alignment: .trailing) {
                        Color.clear.modifier(Flight(id: outgoingID, namespace: flight))
                    }
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard canSend else { return }
                    if let editingItem { submitEdit(editingItem); return }
                    let id = outgoingID
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        link.send(text, attachments: attachments, localID: id, to: session)
                        draft = ""
                        attachments = []
                        outgoingID = "local-\(UUID().uuidString)"
                    }
                    scrollRequest += 1
                } label: {
                    Image(systemName: editingItem == nil ? "arrow.up" : "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(canSend ? MobileTheme.accentFill : MobileTheme.slate.opacity(0.35), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.pyPlain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 4)
        }
        .pyGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), fallback: MobileTheme.card)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(focused ? MobileTheme.accent.opacity(0.35) : MobileTheme.line))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .animation(.snappy, value: attachments.count)
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: canSend)
        .animation(.snappy, value: editingItem?.id)
    }

    private func append(_ attachment: AgentAttachment) {
        let total = attachments.reduce(0) { $0 + $1.data.count } + attachment.data.count
        guard total <= AgentAttachmentLoader.maxTotalBytes else {
            feedback.error(AgentAttachmentError.tooLarge(L("The attachments")), key: "agent-attach")
            return
        }
        attachments.append(attachment)
    }

    private func add(_ providers: [NSItemProvider]) async {
        for provider in providers {
            do {
                if let attachment = try await AgentAttachmentLoader.load(provider) { append(attachment) }
            } catch {
                feedback.error(error, key: "agent-attach")
            }
        }
    }
}

private struct Flight: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .frame, anchor: .bottomTrailing)
        } else {
            content
        }
    }
}

private struct ScrollInteraction: ViewModifier {
    @Binding var active: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                let interacting = phase == .interacting || phase == .decelerating || phase == .tracking
                if interacting != active { active = interacting }
            }
        } else {
            content
        }
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
    var flight: Namespace.ID? = nil
    var pending = false
    var onEdit: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case "user":
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 6) {
                    if let files = item.files, !files.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(files.enumerated()), id: \.offset) { _, name in
                                Label(name == "image" ? L("Photo") : name, systemImage: name == "image" || name.hasSuffix(".jpg") ? "photo" : "doc")
                                    .mobileFont(size: 12, weight: .medium).foregroundStyle(.white).lineLimit(1)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(MobileTheme.accentFill.opacity(0.75), in: Capsule())
                            }
                        }
                    }
                    if !item.text.isEmpty {
                        Text(item.text).mobileFont(size: 15).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(MobileTheme.accentFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .modifier(Flight(id: item.id, namespace: flight))
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contextMenu {
                                Button { UIPasteboard.general.string = item.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                if let onEdit {
                                    Button(action: onEdit) { Label("Edit", systemImage: "pencil") }
                                }
                            }
                    }
                    if pending {
                        Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(MobileTheme.muted)
                            .transition(.opacity)
                    }
                }
                .opacity(pending ? 0.8 : 1)
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
