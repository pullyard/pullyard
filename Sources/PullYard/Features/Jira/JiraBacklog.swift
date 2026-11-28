import SwiftUI

/// The three views of a Jira board, like Jira's own tabs.
enum JiraBoardTab: String, CaseIterable, Identifiable {
    case sprint, backlog, list
    static let storageKey = "jira.board.tab"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sprint: return "Active sprint"
        case .backlog: return "Backlog"
        case .list: return "List"
        }
    }

    var icon: String {
        switch self {
        case .sprint: return "rectangle.split.3x1"
        case .backlog: return "list.bullet.rectangle"
        case .list: return "tablecells"
        }
    }
}

/// A sprint as the backlog shows it: with its dates and state.
struct JiraBacklogSprint: Identifiable, Hashable, Sendable, Codable {
    let id: Int
    let name: String
    let state: String
    var startDate: Date?
    var endDate: Date?
    var goal: String?

    var isActive: Bool { state.lowercased() == "active" }

    nonisolated static func parse(_ v: [String: Any]) -> JiraBacklogSprint? {
        guard let id = v["id"] as? Int, let name = v["name"] as? String else { return nil }
        let goal = (v["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return JiraBacklogSprint(id: id, name: name, state: v["state"] as? String ?? "",
                                 startDate: (v["startDate"] as? String).flatMap(JiraClient.parseDate),
                                 endDate: (v["endDate"] as? String).flatMap(JiraClient.parseDate),
                                 goal: goal?.isEmpty == false ? goal : nil)
    }

    /// "19 Nov – 30 Nov", or nil for a sprint without dates.
    var dates: String? {
        let style = Date.FormatStyle().day().month(.abbreviated)
        switch (startDate, endDate) {
        case let (s?, e?): return "\(s.formatted(style)) – \(e.formatted(style))"
        case let (s?, nil): return "from \(s.formatted(style))"
        case let (nil, e?): return "until \(e.formatted(style))"
        default: return nil
        }
    }
}

/// One block of the backlog: a sprint's issues, or (sprint nil) the backlog itself.
struct JiraBacklogSection: Identifiable, Equatable, Codable {
    var sprint: JiraBacklogSprint?
    var issues: [JiraIssue]

    var id: String { sprint.map { "sprint-\($0.id)" } ?? "backlog" }
    var sprintID: Int? { sprint?.id }
}

struct JiraBacklogSnapshot: Equatable, Codable {
    var sections: [JiraBacklogSection] = []
    var fetchedAt: Date?

    var allIssues: [JiraIssue] { sections.flatMap(\.issues) }

    /// Active sprints first, then future ones in Jira's order, then the backlog.
    static func build(sprints: [JiraBacklogSprint], issues: [Int: [JiraIssue]], backlog: [JiraIssue]) -> JiraBacklogSnapshot {
        let ordered = sprints.filter(\.isActive) + sprints.filter { !$0.isActive }
        var seen = Set<String>()
        func fresh(_ list: [JiraIssue]) -> [JiraIssue] { list.filter { seen.insert($0.key).inserted } }
        var sections = ordered.map { JiraBacklogSection(sprint: $0, issues: fresh(issues[$0.id] ?? [])) }
        sections.append(JiraBacklogSection(sprint: nil, issues: fresh(backlog)))
        return JiraBacklogSnapshot(sections: sections, fetchedAt: Date())
    }

    func sectionIndex(of key: String) -> Int? {
        sections.firstIndex { $0.issues.contains { $0.key == key } }
    }

    /// The snapshot with `key` moved to the end of `sprint`'s section (nil: the backlog).
    /// Unchanged when the issue is unknown, already there, or the sprint isn't shown.
    func moving(_ key: String, toSprint sprint: Int?) -> JiraBacklogSnapshot {
        guard let from = sectionIndex(of: key),
              let to = sections.firstIndex(where: { $0.sprintID == sprint }),
              from != to,
              let i = sections[from].issues.firstIndex(where: { $0.key == key }) else { return self }
        var copy = self
        let issue = copy.sections[from].issues.remove(at: i)
        copy.sections[to].issues.append(issue)
        return copy
    }

    mutating func replace(_ issue: JiraIssue) {
        for s in sections.indices {
            if let i = sections[s].issues.firstIndex(where: { $0.key == issue.key }) {
                sections[s].issues[i] = JiraIssueMerge.merge(issue, into: sections[s].issues[i])
            }
        }
    }
}

/// Where the next page of the List tab starts: a Cloud page token, or an offset on Server/DC.
enum JiraListCursor: Equatable, Codable {
    case token(String)
    case start(Int)
}

struct JiraListPage {
    var issues: [JiraIssue]
    var next: JiraListCursor?

    /// Reads a page from `/rest/api/3/search/jql` (token paging) or `/rest/api/2/search` and the
    /// agile issue endpoints (offset paging, `startAt` is the offset that was asked for).
    nonisolated static func parse(_ o: [String: Any], base: URL, startAt: Int?) -> JiraListPage {
        let issues = (o["issues"] as? [[String: Any]] ?? []).map { JiraClient.parseIssue($0, base: base) }
        var next: JiraListCursor?
        if let token = o["nextPageToken"] as? String, !token.isEmpty, o["isLast"] as? Bool != true {
            next = .token(token)
        } else if let startAt, let total = o["total"] as? Int, !issues.isEmpty, startAt + issues.count < total {
            next = .start(startAt + issues.count)
        }
        return JiraListPage(issues: issues, next: next)
    }
}

struct JiraListSnapshot: Equatable, Codable {
    var issues: [JiraIssue] = []
    var next: JiraListCursor?
    var fetchedAt: Date?

    mutating func append(_ page: JiraListPage) {
        let known = Set(issues.map(\.key))
        issues += page.issues.filter { !known.contains($0.key) }
        next = page.next
    }

    mutating func replace(_ issue: JiraIssue) {
        if let i = issues.firstIndex(where: { $0.key == issue.key }) {
            issues[i] = JiraIssueMerge.merge(issue, into: issues[i])
        }
    }
}

enum JiraIssueMerge {
    /// An issue edited in the ticket overlay, keeping what only the list fetch knows.
    static func merge(_ new: JiraIssue, into old: JiraIssue) -> JiraIssue {
        var merged = new
        merged.connectionID = old.connectionID
        if merged.labels.isEmpty { merged.labels = old.labels }
        if merged.statusID == nil { merged.statusID = old.statusID }
        if merged.created == nil { merged.created = old.created }
        if merged.reporterAvatar == nil, merged.reporter == old.reporter { merged.reporterAvatar = old.reporterAvatar }
        return merged
    }
}

/// The board header's assignee filter and search, shared by all three tabs.
enum JiraIssueFilter {
    static func matches(_ issue: JiraIssue, assignees: Set<String>, query: String) -> Bool {
        matches(issue, assignees: assignees, normalized: normalize(query))
    }

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func matches(_ issue: JiraIssue, assignees: Set<String>, normalized q: String) -> Bool {
        (assignees.isEmpty || assignees.contains(issue.assignee ?? JiraPeopleFilter.unassigned))
            && (q.isEmpty || contains(issue.key, q) || contains(issue.summary, q) || issue.labels.contains { contains($0, q) })
    }

    private static func contains(_ text: String, _ q: String) -> Bool {
        text.range(of: q, options: .caseInsensitive) != nil
    }

    static func filter(_ issues: [JiraIssue], assignees: Set<String>, query: String) -> [JiraIssue] {
        let q = normalize(query)
        if assignees.isEmpty, q.isEmpty { return issues }
        return issues.filter { matches($0, assignees: assignees, normalized: q) }
    }
}

// MARK: - Client

extension JiraClient {
    static let listIssueFields = "summary,status,issuetype,priority,assignee,reporter,created,updated,labels,parent"
    static let listPageSize = 100

    func backlogSprints(board: Int) async throws -> [JiraBacklogSprint] {
        var out: [JiraBacklogSprint] = []
        var start = 0
        while true {
            let o = try json(try await request("/rest/agile/1.0/board/\(board)/sprint?state=active,future&startAt=\(start)&maxResults=50"))
            let values = o["values"] as? [[String: Any]] ?? []
            out += values.compactMap(JiraBacklogSprint.parse)
            start += values.count
            if values.isEmpty || o["isLast"] as? Bool != false || start >= 500 { break }
        }
        return out
    }

    func sprintIssues(board: Int, sprint: Int) async throws -> [JiraIssue] {
        try await agileIssues("/rest/agile/1.0/board/\(board)/sprint/\(sprint)/issue")
    }

    /// The board's backlog: issues in no active or future sprint.
    func backlogIssues(board: Int) async throws -> [JiraIssue] {
        try await agileIssues("/rest/agile/1.0/board/\(board)/backlog")
    }

    private func agileIssues(_ path: String) async throws -> [JiraIssue] {
        var out: [JiraIssue] = []
        var start = 0
        while true {
            let o = try json(try await request("\(path)?fields=\(Self.boardIssueFields)&startAt=\(start)&maxResults=100"))
            let issues = o["issues"] as? [[String: Any]] ?? []
            out += issues.map { Self.parseIssue($0, base: base) }
            start += issues.count
            let total = o["total"] as? Int ?? out.count
            if issues.isEmpty || start >= total || start >= 2000 { break }
        }
        return out
    }

    /// One page of every issue in the project, newest first. Cloud pages with tokens
    /// (`/rest/api/3/search/jql`); Server/DC, which lacks it, pages `/rest/api/2/search` by offset.
    /// A board without a project falls back to the board's own issues.
    func listPage(project: String?, board: Int, after cursor: JiraListCursor?) async throws -> JiraListPage {
        let fields = "fields=\(Self.listIssueFields)&maxResults=\(Self.listPageSize)"
        guard let project, !project.isEmpty else {
            let start = { if case .start(let n)? = cursor { return n }; return 0 }()
            let jql = Self.encode("ORDER BY created DESC")
            let o = try json(try await request("/rest/agile/1.0/board/\(board)/issue?\(fields)&jql=\(jql)&startAt=\(start)"))
            return JiraListPage.parse(o, base: base, startAt: start)
        }
        let jql = Self.encode("project = \"\(project)\" ORDER BY created DESC")
        switch cursor {
        case .start(let start)?:
            let o = try json(try await request("/rest/api/2/search?jql=\(jql)&\(fields)&startAt=\(start)"))
            return JiraListPage.parse(o, base: base, startAt: start)
        case .token(let token)?:
            let o = try json(try await request("/rest/api/3/search/jql?jql=\(jql)&\(fields)&nextPageToken=\(Self.encode(token))"))
            return JiraListPage.parse(o, base: base, startAt: nil)
        case nil:
            do {
                let o = try json(try await request("/rest/api/3/search/jql?jql=\(jql)&\(fields)"))
                return JiraListPage.parse(o, base: base, startAt: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let o = try json(try await request("/rest/api/2/search?jql=\(jql)&\(fields)&startAt=0"))
                return JiraListPage.parse(o, base: base, startAt: 0)
            }
        }
    }
}

// MARK: - Model

/// Backlog and List data per Jira account and board, cached in memory and on disk like the board,
/// so switching tabs, accounts or boards shows the last data at once while a fresh fetch runs.
@MainActor
@Observable
final class JiraWorkModel {
    static let shared = JiraWorkModel()

    private(set) var key: String?
    private(set) var backlog = JiraBacklogSnapshot()
    private(set) var list = JiraListSnapshot()
    private(set) var loadingBacklog = false
    private(set) var loadingList = false
    private(set) var loadingMore = false
    var error: String?
    var moving: Set<String> = []

    @ObservationIgnored private var connectionID: String?
    @ObservationIgnored private var board: JiraBoard?
    @ObservationIgnored private var backlogCache: [String: JiraBacklogSnapshot] = [:]
    @ObservationIgnored private var listCache: [String: JiraListSnapshot] = [:]
    @ObservationIgnored private var backlogGen = 0
    @ObservationIgnored private var listGen = 0
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullYard/jira-work", isDirectory: true)
    }

    private var client: JiraClient? { JiraConnections.shared.client(for: connectionID) }

    /// Points the model at an account's board, showing its cached backlog and list right away.
    func show(connection: String?, board: JiraBoard?) {
        let next = connection.flatMap { c in board.map { "\(c)-\($0.id)" } }
        guard next != key else { return }
        if let key { backlogCache[key] = backlog; listCache[key] = list }
        key = next
        connectionID = connection
        self.board = board
        backlog = next.map { cached($0, "backlog") ?? JiraBacklogSnapshot() } ?? JiraBacklogSnapshot()
        list = next.map { cached($0, "list") ?? JiraListSnapshot() } ?? JiraListSnapshot()
        loadingBacklog = false
        loadingList = false
        loadingMore = false
        error = nil
        moving = []
    }

    func loadBacklog() async {
        guard let client, let board, let key, let id = connectionID else { return }
        backlogGen += 1
        let gen = backlogGen
        loadingBacklog = true
        defer { if gen == backlogGen { loadingBacklog = false } }
        do {
            async let backlogList = client.backlogIssues(board: board.id)
            let sprints = board.isScrum ? ((try? await client.backlogSprints(board: board.id)) ?? []) : []
            var bySprint: [Int: [JiraIssue]] = [:]
            try await withThrowingTaskGroup(of: (Int, [JiraIssue]).self) { group in
                for s in sprints { group.addTask { (s.id, try await client.sprintIssues(board: board.id, sprint: s.id)) } }
                for try await (sid, issues) in group { bySprint[sid] = issues }
            }
            // A kanban board without a backlog has no backlog endpoint; it just shows empty.
            let rest = (try? await backlogList) ?? []
            guard key == self.key, gen == backlogGen else { return }
            var snap = JiraBacklogSnapshot.build(sprints: sprints, issues: bySprint, backlog: rest)
            for s in snap.sections.indices {
                snap.sections[s].issues = snap.sections[s].issues.map { var i = $0; i.connectionID = id; return i }
            }
            backlog = snap
            store(key, "backlog", snap)
            error = nil
        } catch {
            if !(error is CancellationError), key == self.key { self.error = error.localizedDescription }
        }
    }

    /// The first page again; what was loaded stays on screen until it arrives.
    func loadList() async {
        guard let client, let board, let key, let id = connectionID else { return }
        listGen += 1
        let gen = listGen
        loadingList = true
        defer { if gen == listGen { loadingList = false } }
        do {
            let page = try await client.listPage(project: board.projectKey, board: board.id, after: nil)
            guard key == self.key, gen == listGen else { return }
            var snap = JiraListSnapshot()
            snap.append(Self.tag(page, id))
            snap.fetchedAt = Date()
            list = snap
            store(key, "list", snap)
            error = nil
        } catch {
            if !(error is CancellationError), key == self.key { self.error = error.localizedDescription }
        }
    }

    func loadMore() async {
        guard let client, let board, let key, let id = connectionID, let cursor = list.next, !loadingMore else { return }
        let gen = listGen
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.listPage(project: board.projectKey, board: board.id, after: cursor)
            guard key == self.key, gen == listGen else { return }
            list.append(Self.tag(page, id))
            store(key, "list", list)
            error = nil
        } catch {
            if !(error is CancellationError), key == self.key { self.error = error.localizedDescription }
        }
    }

    private static func tag(_ page: JiraListPage, _ id: String) -> JiraListPage {
        JiraListPage(issues: page.issues.map { var i = $0; i.connectionID = id; return i }, next: page.next)
    }

    /// Drops an issue on a sprint (nil: the backlog). It moves at once and goes back if Jira refuses.
    func move(_ issueKey: String, toSprint sprint: Int?) async {
        guard let client, let key else { return }
        let next = backlog.moving(issueKey, toSprint: sprint)
        guard next != backlog else { return }
        let undo = backlog
        withAnimation(Motion.smooth) { backlog = next }
        moving.insert(issueKey)
        defer { moving.remove(issueKey) }
        do {
            try await client.move(issueKey, toSprint: sprint)
            guard key == self.key else { return }
            store(key, "backlog", backlog)
            error = nil
            // The active sprint board may have gained or lost this issue.
            Task { await JiraBoardModel.shared.loadBoard() }
        } catch {
            guard key == self.key else { return }
            withAnimation(Motion.smooth) { backlog = undo }
            self.error = error.localizedDescription
        }
    }

    func replace(_ issue: JiraIssue) {
        guard let key else { return }
        backlog.replace(issue)
        list.replace(issue)
        store(key, "backlog", backlog)
        store(key, "list", list)
    }

    // MARK: Cache

    private func file(_ key: String, _ kind: String) -> URL {
        directory.appendingPathComponent("\(key.filter { $0.isLetter || $0.isNumber || $0 == "-" })-\(kind).json")
    }

    private func cached<T: Decodable>(_ key: String, _ kind: String) -> T? {
        if kind == "backlog", let hit = backlogCache[key] as? T { return hit }
        if kind == "list", let hit = listCache[key] as? T { return hit }
        guard let data = try? Data(contentsOf: file(key, kind)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func store<T: Encodable>(_ key: String, _ kind: String, _ value: T) {
        if let v = value as? JiraBacklogSnapshot { backlogCache[key] = v }
        if let v = value as? JiraListSnapshot { listCache[key] = v }
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = file(key, kind)
        let dir = directory
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Tabs

/// Active sprint · Backlog · List, underlined like Jira's board tabs.
struct JiraBoardTabsBar: View {
    @Binding var selection: JiraBoardTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(JiraBoardTab.allCases) { tab in
                let on = selection == tab
                Button {
                    withAnimation(Motion.smooth) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 11, weight: .semibold))
                        Text(tab.title).font(.syCallout.weight(on ? .semibold : .medium))
                    }
                    .foregroundStyle(on ? Color.syText : Color.syMuted)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.syAccent.opacity(0.12))
                                .matchedGeometryEffect(id: "tab.bg", in: ns)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if on {
                            Capsule().fill(Color.syAccent).frame(height: 2).padding(.horizontal, 8).offset(y: 5)
                                .matchedGeometryEffect(id: "tab.line", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(JiraTabButtonStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Board views")
    }
}

private struct JiraTabButtonStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.syText.opacity(configuration.isPressed ? 0.08 : hover ? 0.05 : 0)))
            .onHover { hover = $0 }
    }
}

// MARK: - Backlog

struct JiraBacklogView: View, Equatable {
    let snapshot: JiraBacklogSnapshot
    let isScrum: Bool
    let moving: Set<String>
    let assignees: Set<String>
    let query: String
    let onOpen: (JiraIssue) -> Void
    let onMove: (String, Int?) -> Void
    @State private var collapsed: Set<String> = []
    @State private var targetSlice: String?

    static func == (a: Self, b: Self) -> Bool {
        a.snapshot == b.snapshot && a.isScrum == b.isScrum && a.moving == b.moving
            && a.assignees == b.assignees && a.query == b.query
    }

    private var filtering: Bool { !assignees.isEmpty || !JiraIssueFilter.normalize(query).isEmpty }

    private enum Slice: Identifiable {
        case header(JiraBacklogSection, visible: Int)
        case row(JiraBacklogSection, JiraIssue, first: Bool, last: Bool)
        case empty(JiraBacklogSection)

        var section: JiraBacklogSection {
            switch self {
            case .header(let s, _), .row(let s, _, _, _), .empty(let s): return s
            }
        }

        var id: String {
            switch self {
            case .header(let s, _): return "\(s.id)/header"
            case .row(let s, let issue, _, _): return "\(s.id)/\(issue.key)"
            case .empty(let s): return "\(s.id)/empty"
            }
        }

        var closesSection: Bool {
            switch self {
            case .header: return false
            case .row(_, _, _, let last): return last
            case .empty: return true
            }
        }
    }

    private var slices: [Slice] {
        var out: [Slice] = []
        for section in snapshot.sections {
            let visible = JiraIssueFilter.filter(section.issues, assignees: assignees, query: query)
            out.append(.header(section, visible: visible.count))
            if collapsed.contains(section.id) { continue }
            if visible.isEmpty {
                out.append(.empty(section))
            } else {
                for (i, issue) in visible.enumerated() {
                    out.append(.row(section, issue, first: i == 0, last: i == visible.count - 1))
                }
            }
        }
        return out
    }

    var body: some View {
        let targetSection = targetSlice.flatMap { id in id.split(separator: "/").first.map(String.init) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(slices) { slice in
                    let section = slice.section
                    let isCollapsed = collapsed.contains(section.id)
                    sliceContent(slice, collapsed: isCollapsed)
                        .modifier(JiraSliceSurface(
                            top: { if case .header = slice { return true }; return false }(),
                            bottom: slice.closesSection || isCollapsed,
                            radius: 16,
                            fill: Color.syPanel.opacity(0.6),
                            stroke: targetSection == section.id ? Color.syAccent : Color.syLine,
                            lineWidth: targetSection == section.id ? 1.5 : 1
                        ))
                        .padding(.bottom, slice.closesSection || isCollapsed ? 14 : 0)
                        .dropDestination(for: String.self) { keys, _ in
                            guard isScrum, let key = keys.first, !section.issues.contains(where: { $0.key == key }) else { return false }
                            onMove(key, section.sprintID)
                            return true
                        } isTargeted: { on in
                            if on, isScrum { targetSlice = slice.id } else if targetSlice == slice.id { targetSlice = nil }
                        }
                }
            }
            .padding(16)
            .animation(Motion.fade, value: targetSection)
        }
    }

    @ViewBuilder
    private func sliceContent(_ slice: Slice, collapsed isCollapsed: Bool) -> some View {
        switch slice {
        case .header(let section, let visible):
            JiraBacklogSectionHeader(section: section, visible: visible, filtering: filtering, collapsed: isCollapsed) {
                withAnimation(Motion.smooth) {
                    if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
                }
            }
        case .row(_, let issue, let first, let last):
            JiraBacklogRow(issue: issue, busy: moving.contains(issue.key)) { onOpen(issue) }
                .draggable(issue.key)
                .overlay(alignment: .bottom) { if !last { Divider().opacity(0.5).padding(.horizontal, 1) } }
                .modifier(JiraSliceSurface(top: first, bottom: last, radius: 12, fill: Color.syRaised, stroke: Color.syLine, lineWidth: 1))
                .padding(.horizontal, 8)
                .padding(.bottom, last ? 8 : 0)
        case .empty(let section):
            Text(emptyText(section))
                .font(.syCallout)
                .foregroundStyle(Color.syDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
    }

    private func emptyText(_ section: JiraBacklogSection) -> String {
        if filtering, !section.issues.isEmpty { return "Nothing here matches the filter" }
        if section.sprint == nil { return "Your backlog is empty" }
        return isScrum ? "Plan this sprint by dragging work items here" : "No work items"
    }
}

private struct JiraSliceSurface: ViewModifier {
    let top: Bool
    let bottom: Bool
    let radius: CGFloat
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0,
            bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0,
            topTrailingRadius: top ? radius : 0,
            style: .continuous
        )
        content
            .background(shape.fill(fill))
            .overlay {
                shape
                    .strokeBorder(stroke, lineWidth: lineWidth)
                    .padding(.top, top ? 0 : -4)
                    .padding(.bottom, bottom ? 0 : -4)
                    .clipped()
                    .allowsHitTesting(false)
            }
    }
}

private struct JiraBacklogSectionHeader: View {
    let section: JiraBacklogSection
    let visible: Int
    let filtering: Bool
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.syMuted)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Text(section.sprint?.name ?? "Backlog")
                    .font(.syCallout.weight(.semibold))
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                if let dates = section.sprint?.dates {
                    Text(dates).font(.syCallout).foregroundStyle(Color.syMuted).lineLimit(1)
                }
                Text(countLabel).font(.syCallout.monospacedDigit()).foregroundStyle(Color.syMuted)
                if section.sprint?.isActive == true {
                    Text("ACTIVE")
                        .font(.syCaption2.weight(.bold))
                        .foregroundStyle(Color.syGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.syGreen.opacity(0.14)))
                }
                Spacer(minLength: 8)
                if !section.issues.isEmpty { statusSummary }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.sprint?.goal ?? (collapsed ? "Expand" : "Collapse"))
        .accessibilityLabel("\(section.sprint?.name ?? "Backlog"), \(countLabel)")
        .accessibilityHint(collapsed ? "Expand" : "Collapse")
    }

    private var countLabel: String {
        let total = section.issues.count
        let noun = total == 1 ? "work item" : "work items"
        return filtering && visible != total ? "(\(visible) of \(total) \(noun))" : "(\(total) \(noun))"
    }

    private var statusSummary: some View {
        var todo = 0, doing = 0, done = 0
        for issue in section.issues {
            switch issue.statusCategory {
            case "indeterminate": doing += 1
            case "done": done += 1
            default: todo += 1
            }
        }
        let counts = [(todo, Color.syMuted), (doing, Color.sySky), (done, Color.syGreen)]
        return HStack(spacing: 4) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, c in
                Text("\(c.0)")
                    .font(.syCaption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(c.1)
                    .frame(minWidth: 18)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(c.1.opacity(0.14)))
            }
        }
        .help("To do · In progress · Done")
    }
}

struct JiraBacklogRow: View {
    let issue: JiraIssue
    var busy = false
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: JiraStyle.typeIcon(issue.type))
                .font(.syCaption)
                .foregroundStyle(JiraStyle.typeColor(issue.type))
                .frame(width: 14)
            Text(issue.key)
                .font(.syCaption.weight(.semibold).monospaced())
                .foregroundStyle(issue.statusCategory == "done" ? Color.syDim : Color.syMuted)
                .strikethrough(issue.statusCategory == "done")
                .fixedSize()
            Text(issue.summary)
                .font(.syBody)
                .foregroundStyle(Color.syText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if busy { WakeLoader() }
            JiraStatusPill(status: issue.status, category: issue.statusCategory)
            JiraPriorityIcon(priority: issue.priority).frame(width: 16)
            JiraAssigneeAvatar(name: issue.assignee, avatar: issue.assigneeAvatar, size: 22)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.syText.opacity(hover ? 0.05 : 0))
        .contentShape(Rectangle())
        .opacity(busy ? 0.6 : 1)
        // A tap gesture, not a Button, so the row can be dragged to another sprint.
        .onTapGesture(perform: onOpen)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.status)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", onOpen)
        .contextMenu { JiraIssueContextMenu(issue: issue) }
    }
}

struct JiraIssueContextMenu: View {
    let issue: JiraIssue

    var body: some View {
        Button("Open in Jira") { openInBrowser(issue.url) }
        Button("Copy Key") { copyToPasteboard(issue.key) }
        Button("Copy Link") { copyToPasteboard(issue.url) }
    }
}

struct JiraPriorityIcon: View {
    let priority: String?

    var body: some View {
        if let p = priority {
            Image(systemName: Self.icon(p))
                .font(.syCaption.weight(.bold))
                .foregroundStyle(JiraStyle.priorityColor(p))
                .help("Priority: \(p)")
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    static func icon(_ p: String) -> String {
        switch p.lowercased() {
        case "highest", "blocker", "critical": return "chevron.up.2"
        case "high", "major": return "chevron.up"
        case "medium": return "equal"
        case "low", "minor": return "chevron.down"
        default: return "chevron.down.2"
        }
    }
}

struct JiraAssigneeAvatar: View {
    let name: String?
    let avatar: String?
    var size: CGFloat = 22

    var body: some View {
        if let name {
            JiraPersonAvatar(person: JiraPerson(name: name, avatar: avatar), size: size).help(name)
        } else {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: size * 0.85))
                .foregroundStyle(Color.syDim)
                .frame(width: size, height: size)
                .help("Unassigned")
        }
    }
}

struct JiraBacklogSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<3, id: \.self) { section in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        ShimmerBar(width: 10, height: 10)
                        ShimmerBar(width: section == 2 ? 70 : 140, height: 12)
                        ShimmerBar(width: 90, height: 10)
                        Spacer()
                    }
                    .padding(12)
                    VStack(spacing: 0) {
                        ForEach(0..<(section == 0 ? 5 : 3), id: \.self) { row in
                            HStack(spacing: 10) {
                                ShimmerBar(width: 14, height: 12)
                                ShimmerBar(width: 70, height: 10)
                                ShimmerBar(width: row % 2 == 0 ? 320 : 240, height: 11)
                                Spacer()
                                ShimmerBar(width: 64, height: 18, radius: 9)
                                Circle().fill(Color.syLine).frame(width: 22, height: 22)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 40)
                        }
                    }
                    .pyCardSurface(radius: 12)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.syPanel.opacity(0.6)))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel("Loading backlog")
    }
}

// MARK: - List

private enum JiraListColumns {
    static let assignee: CGFloat = 170
    static let reporter: CGFloat = 170
    static let priority: CGFloat = 100
    static let status: CGFloat = 150
    static let created: CGFloat = 110
    static let minWidth: CGFloat = 1000
}

struct JiraIssueListView: View, Equatable {
    let issues: [JiraIssue]
    let total: Int
    let hasMore: Bool
    let loadingMore: Bool
    let onOpen: (JiraIssue) -> Void
    let onLoadMore: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.total == b.total && a.hasMore == b.hasMore && a.loadingMore == b.loadingMore && a.issues == b.issues
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(JiraListColumns.minWidth, geo.size.width - 32)
            ScrollView(width > geo.size.width - 32 ? [.vertical, .horizontal] : .vertical) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(issues) { issue in
                            JiraListRow(issue: issue) { onOpen(issue) }
                                .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                        }
                        footer
                    } header: {
                        headerRow
                    }
                }
                .frame(width: width)
                .pyCardSurface(radius: 12)
                .padding(16)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            title("Work").frame(maxWidth: .infinity, alignment: .leading)
            title("Assignee").frame(width: JiraListColumns.assignee, alignment: .leading)
            title("Reporter").frame(width: JiraListColumns.reporter, alignment: .leading)
            title("Priority").frame(width: JiraListColumns.priority, alignment: .leading)
            title("Status").frame(width: JiraListColumns.status, alignment: .leading)
            title("Created").frame(width: JiraListColumns.created, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous).fill(Color.syRaised))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.syLineStrong).frame(height: 1) }
    }

    private func title(_ s: String) -> some View {
        Text(s).font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Text(issues.count == total ? "\(total) loaded" : "\(issues.count) shown · \(total) loaded")
                .font(.syCaption.monospacedDigit())
                .foregroundStyle(Color.syMuted)
            if hasMore {
                if loadingMore {
                    WakeLoader()
                } else {
                    Button("Load more", action: onLoadMore)
                        .buttonStyle(.borderless)
                        .font(.syCaption.weight(.semibold))
                }
            }
            Spacer()
        }
        .frame(height: 44)
    }
}

private struct JiraListRow: View {
    let issue: JiraIssue
    let onOpen: () -> Void
    @State private var hover = false
    private static let createdStyle = Date.FormatStyle(date: .abbreviated, time: .omitted)

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: JiraStyle.typeIcon(issue.type))
                    .font(.syCaption)
                    .foregroundStyle(JiraStyle.typeColor(issue.type))
                    .frame(width: 14)
                Text(issue.key)
                    .font(.syCaption.weight(.semibold).monospaced())
                    .foregroundStyle(Color.sySky)
                    .fixedSize()
                Text(issue.summary)
                    .font(.syBody)
                    .foregroundStyle(Color.syText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            person(issue.assignee, issue.assigneeAvatar, empty: "Unassigned").frame(width: JiraListColumns.assignee, alignment: .leading)
            person(issue.reporter, issue.reporterAvatar, empty: "—").frame(width: JiraListColumns.reporter, alignment: .leading)
            HStack(spacing: 6) {
                JiraPriorityIcon(priority: issue.priority)
                Text(issue.priority ?? "—").font(.syCallout).foregroundStyle(Color.syText).lineLimit(1)
            }
            .frame(width: JiraListColumns.priority, alignment: .leading)
            JiraStatusPill(status: issue.status, category: issue.statusCategory)
                .frame(width: JiraListColumns.status, alignment: .leading)
            Text(issue.created.map { $0.formatted(Self.createdStyle) } ?? "—")
                .font(.syCallout.monospacedDigit())
                .foregroundStyle(Color.syMuted)
                .lineLimit(1)
                .frame(width: JiraListColumns.created, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color.syText.opacity(hover ? 0.05 : 0))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(issue.key), \(issue.summary), \(issue.status), \(issue.assignee ?? "unassigned")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open", onOpen)
        .contextMenu { JiraIssueContextMenu(issue: issue) }
    }

    private func person(_ name: String?, _ avatar: String?, empty: String) -> some View {
        HStack(spacing: 8) {
            JiraAssigneeAvatar(name: name, avatar: avatar, size: 22)
            Text(name ?? empty)
                .font(.syCallout)
                .foregroundStyle(name == nil ? Color.syMuted : Color.syText)
                .lineLimit(1)
        }
    }
}

struct JiraListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack { ShimmerBar(width: 60, height: 10); Spacer() }
                .padding(.horizontal, 14)
                .frame(height: 36)
            ForEach(0..<12, id: \.self) { row in
                HStack(spacing: 12) {
                    ShimmerBar(width: 14, height: 12)
                    ShimmerBar(width: 70, height: 10)
                    ShimmerBar(width: row % 3 == 0 ? 300 : 220, height: 11)
                    Spacer()
                    Circle().fill(Color.syLine).frame(width: 22, height: 22)
                    ShimmerBar(width: 110, height: 10)
                    ShimmerBar(width: 64, height: 18, radius: 9)
                    ShimmerBar(width: 80, height: 10)
                }
                .padding(.horizontal, 14)
                .frame(height: 42)
                Divider().opacity(0.5)
            }
            Spacer(minLength: 0)
        }
        .pyCardSurface(radius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement()
        .accessibilityLabel("Loading issues")
    }
}
