import SwiftUI

enum OverviewTileKind: String, CaseIterable, Identifiable {
    case mine, readyToMerge, failing, changesRequested, assigned, mentioned, reviewed, inbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: return "My pull requests"
        case .readyToMerge: return "Ready to merge"
        case .failing: return "Failing checks"
        case .changesRequested: return "Changes requested"
        case .assigned: return "Assigned to me"
        case .mentioned: return "Mentioned"
        case .reviewed: return "Reviewed by me"
        case .inbox: return "Unread inbox"
        }
    }

    var symbol: String {
        switch self {
        case .mine: return "person.fill"
        case .readyToMerge: return "arrow.triangle.merge"
        case .failing: return "xmark.octagon.fill"
        case .changesRequested: return "arrow.uturn.backward.circle.fill"
        case .assigned: return "person.badge.clock.fill"
        case .mentioned: return "at"
        case .reviewed: return "checkmark.bubble.fill"
        case .inbox: return "tray.full.fill"
        }
    }

    var tint: Color {
        switch self {
        case .mine: return .syViolet
        case .readyToMerge: return .syGreen
        case .failing: return .syRed
        case .changesRequested: return .syAmberInk
        case .assigned: return .syTeal
        case .mentioned: return .syIndigo
        case .reviewed: return .sySky
        case .inbox: return .sySlate
        }
    }

    var refine: String? {
        switch self {
        case .readyToMerge: return "review:approved status:success"
        case .failing: return "status:failure"
        case .changesRequested: return "review:changes_requested"
        default: return nil
        }
    }

    var section: SidebarSection {
        switch self {
        case .mine, .readyToMerge, .failing, .changesRequested: return .prs(.mine)
        case .assigned: return .prs(.assigned)
        case .mentioned: return .prs(.mentioned)
        case .reviewed: return .prs(.reviewed)
        case .inbox: return .notifications
        }
    }

    var query: String? {
        switch self {
        case .mine, .inbox: return nil
        case .readyToMerge, .failing, .changesRequested: return "\(PRFilter.mine.query) is:pr is:open archived:false \(refine ?? "")"
        case .assigned: return "\(PRFilter.assigned.query) is:pr is:open archived:false"
        case .mentioned: return "\(PRFilter.mentioned.query) is:pr is:open archived:false"
        case .reviewed: return "\(PRFilter.reviewed.query) is:pr is:open archived:false"
        }
    }
}

@Observable
@MainActor
final class OverviewModel {
    static let shared = OverviewModel()

    var counts: [OverviewTileKind: Int] = [:]
    var loading = false
    var lastUpdated: Date?
    var error: String?

    func load(api: GitHubAPI?, force: Bool = false) async {
        guard let api, !loading else { return }
        if !force, let lastUpdated, Date().timeIntervalSince(lastUpdated) < 120, !counts.isEmpty { return }
        loading = true
        defer { loading = false }
        let kinds = OverviewTileKind.allCases.filter { $0.query != nil }
        let fields = kinds.map { "\($0.rawValue): search(type: ISSUE, first: 0, query: $\($0.rawValue)) { issueCount }" }.joined(separator: " ")
        let params = kinds.map { "$\($0.rawValue): String!" }.joined(separator: ", ")
        let query = "query(\(params)) { \(fields) }"
        var vars: [String: Any?] = [:]
        for kind in kinds { vars[kind.rawValue] = kind.query }
        struct Count: Decodable { let issueCount: Int }
        do {
            let result: [String: Count] = try await api.graphQL(query, vars)
            for kind in kinds {
                if let n = result[kind.rawValue]?.issueCount { counts[kind] = n }
            }
            error = nil
            lastUpdated = Date()
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }
}

struct OverviewView: View {
    @Environment(AppModel.self) private var app
    @State private var model = OverviewModel.shared
    @State private var appeared = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                hero
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(Array(OverviewTileKind.allCases.enumerated()), id: \.element) { index, kind in
                        Button { open(kind) } label: {
                            OverviewTile(kind: kind, count: count(kind))
                        }
                        .buttonStyle(PressScale())
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(Motion.reduced ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.45).delay(0.05 + Double(index) * 0.03), value: appeared)
                    }
                }
                agentsCard
                recentStrip
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background {
            ZStack {
                Color.syPanel
                if Theme.isBrand { BrandAurora().opacity(0.9) }
            }
            .ignoresSafeArea()
        }
        .columnTitle("Overview", subtitle: subtitle)
        .panelToolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshPill(updated: model.lastUpdated, refreshing: model.loading, error: model.error) {
                    Task { await reload(force: true) }
                }
            }
        }
        .task(id: "\(app.cacheAccount ?? "")|\(app.api != nil)") {
            appeared = true
            await reload(force: model.counts.isEmpty)
        }
        .onChange(of: app.refreshTick) { Task { await reload(force: true) } }
    }

    private var subtitle: String {
        let n = app.reviewRequestCount
        return n == 0 ? "Nothing waiting" : plural(n, "review waiting", "reviews waiting")
    }

    private func reload(force: Bool) async {
        await model.load(api: app.api, force: force)
    }

    private func count(_ kind: OverviewTileKind) -> Int? {
        switch kind {
        case .mine: return app.myPRCount
        case .inbox: return app.unreadCount
        default: return model.counts[kind]
        }
    }

    private func open(_ kind: OverviewTileKind) {
        let key = "search|pr|\(PRFilter.mine.query)"
        if kind.section == .prs(.mine) {
            ListFilterMemory.text[key] = kind.refine
        }
        app.section = kind.section
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syMuted)
                Text(firstName)
                    .font(.system(size: TextZoom.shared.size(30), weight: .semibold, design: .serif))
                    .foregroundStyle(Color.syText)
            }
            Spacer()
            if let summary = daySummary {
                Text(summary)
                    .font(.syCallout)
                    .foregroundStyle(Color.syMuted)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var firstName: String {
        let name = app.user?.name?.split(separator: " ").first.map(String.init)
        return name ?? app.user?.login ?? "Reviewer"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var daySummary: String? {
        var parts: [String] = []
        if let failing = model.counts[.failing], failing > 0 { parts.append(plural(failing, "PR with failing checks", "PRs with failing checks")) }
        if let ready = model.counts[.readyToMerge], ready > 0 { parts.append("\(ready) ready to merge") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var hero: some View {
        let waiting = app.reviewRequests
        let count = app.reviewRequestCount
        return VStack(alignment: .leading, spacing: 14) {
            Button { app.section = .prs(.reviewRequested) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(count)")
                        .font(.system(size: TextZoom.shared.size(52), weight: .bold, design: .rounded))
                        .foregroundStyle(count == 0 ? Color.syGreen : Color.syCoral)
                        .contentTransition(.numericText())
                        .animation(Motion.gentle, value: count)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(count == 1 ? "review waiting" : "reviews waiting")
                            .font(.sy(size: 18, weight: .semibold))
                            .foregroundStyle(Color.syText)
                        Text("for you")
                            .font(.syCallout)
                            .foregroundStyle(Color.syMuted)
                    }
                    Spacer()
                    if count > 0 {
                        HStack(spacing: 4) {
                            Text("Open queue")
                            Image(systemName: "chevron.right")
                        }
                        .font(.syCallout.weight(.semibold))
                        .foregroundStyle(Color.syLink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if count == 0 {
                HStack(spacing: 16) {
                    DrawnLogoMark(key: "overview-calm", size: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calm waters")
                            .font(.system(size: TextZoom.shared.size(18), weight: .semibold, design: .serif))
                            .foregroundStyle(Color.syText)
                        Text("Nothing is waiting for your review.")
                            .font(.syCallout)
                            .foregroundStyle(Color.syMuted)
                    }
                }
                .padding(.vertical, 4)
            } else if !waiting.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(waiting.prefix(5).enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Rectangle().fill(Color.syLine).frame(height: 1) }
                        OverviewRow(item: item) { app.open(item.route) }
                    }
                }
                if waiting.count > 5 {
                    Button("Show all \(count)") { app.section = .prs(.reviewRequested) }
                        .buttonStyle(.link)
                        .font(.syCallout)
                }
            }
        }
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.syRaised)
                .overlay(alignment: .topLeading) {
                    if count > 0 {
                        LinearGradient(colors: [Color.syCoral.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.syLine))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
    }

    @ViewBuilder
    private var agentsCard: some View {
        let running = app.claude.tabs.filter(\.running).count
        let attention = app.claude.attentionCount
        HStack(spacing: 14) {
            Image(systemName: "terminal.fill")
                .font(.syIcon(16))
                .foregroundStyle(Color.syCoral)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.syCoral.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Agents")
                    .font(.sy(size: 15, weight: .semibold))
                    .foregroundStyle(Color.syText)
                Text(agentsLine(running: running, attention: attention))
                    .font(.syCallout)
                    .foregroundStyle(attention > 0 ? Color.syCoralInk : Color.syMuted)
            }
            Spacer()
            if running > 0 { PYLoader(size: 14, label: "Agents working") }
            Button(running + attention > 0 ? "Open Agents" : "New session") {
                if running + attention > 0 { app.section = .claude } else { app.newAgentSession() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.syAgentFill)
            .controlSize(.regular)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.syLine))
    }

    private func agentsLine(running: Int, attention: Int) -> String {
        if attention > 0 { return plural(attention, "session needs you", "sessions need you") }
        if running > 0 { return plural(running, "session working", "sessions working") }
        return "Fix review comments and failing checks with an agent"
    }

    @ViewBuilder
    private var recentStrip: some View {
        let recent = Array(app.recentRoutes.compactMap { ShortLink.ref(route: $0) }.prefix(8))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Recently opened", systemImage: "clock.arrow.circlepath")
                    .font(.sy(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Color.syMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(app.recentRoutes.prefix(8).enumerated()), id: \.offset) { _, route in
                            if let ref = ShortLink.ref(route: route) {
                                Button { app.open(route) } label: {
                                    Text(ShortLink.make(ref))
                                        .font(.syCallout.monospaced())
                                        .foregroundStyle(Color.syText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Capsule().fill(Color.syRaised))
                                        .overlay(Capsule().strokeBorder(Color.syLine))
                                }
                                .buttonStyle(PressScale())
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct OverviewTile: View {
    let kind: OverviewTileKind
    let count: Int?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: kind.symbol)
                    .font(.syIcon(14))
                    .foregroundStyle(kind.tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(kind.tint.opacity(0.14)))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.syIcon(10))
                    .foregroundStyle(Color.syDim)
                    .opacity(hovering ? 1 : 0.5)
            }
            Text(count.map(String.init) ?? "–")
                .font(.system(size: TextZoom.shared.size(28), weight: .bold, design: .rounded))
                .foregroundStyle((count ?? 0) > 0 ? Color.syText : Color.syDim)
                .contentTransition(.numericText())
                .animation(Motion.gentle, value: count)
            Text(kind.title)
                .font(.syCallout.weight(.semibold))
                .foregroundStyle(Color.syMuted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(hovering ? kind.tint.opacity(0.45) : Color.syLine))
        .shadow(color: .black.opacity(hovering ? 0.08 : 0.03), radius: hovering ? 12 : 6, y: hovering ? 4 : 2)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: Motion.Dur.fast)) { hovering = h } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title), \(count.map(String.init) ?? "loading")")
    }
}

private struct OverviewRow: View {
    let item: SearchItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Avatar(url: item.author?.avatarUrl, size: 26, ring: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.syBody.weight(.medium))
                        .foregroundStyle(Color.syText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(item.repository.nameWithOwner)#\(item.number)").font(.syCaption.monospaced())
                        Text("·")
                        Text(item.author?.login ?? "")
                        Text("·")
                        Text(Fmt.rel(item.updatedAt))
                    }
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                CIChip(state: item.ciState)
                if let a = item.additions, let d = item.deletions { DiffStat(additions: a, deletions: d) }
                Image(systemName: "chevron.right").font(.syIcon(10)).foregroundStyle(Color.syDim)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(radius: 8)
        .help(item.title)
    }
}
