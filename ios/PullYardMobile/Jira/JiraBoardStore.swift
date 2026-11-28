import Foundation
import SwiftUI

struct JiraBoardInfo: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let type: String
    let projectKey: String?

    var isScrum: Bool { type.lowercased() == "scrum" }
}

struct JiraColumnInfo: Identifiable, Hashable {
    let name: String
    let statusIDs: [String]
    var id: String { name }
}

struct JiraSprintInfo: Identifiable, Hashable {
    let id: Int
    let name: String
    let state: String
    let endDate: Date?
}

struct JiraCard: Identifiable, Hashable {
    var id: String { key }
    let key: String
    var summary: String
    var status: String
    var statusID: String?
    var statusCategory: String
    var type: String?
    var priority: String?
    var assignee: String?
    var labels: [String]
    var updated: Date?
    let url: URL
}

struct JiraMove: Identifiable, Hashable {
    let id: String
    let name: String
    let toID: String?
    let toName: String
    let toCategory: String
}

struct JiraBacklogGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let active: Bool
    var cards: [JiraCard]
}

enum JiraBoardTab: String, CaseIterable, Identifiable {
    case sprint, backlog, list
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sprint: "Active sprint"
        case .backlog: "Backlog"
        case .list: "List"
        }
    }
}

extension JiraREST {
    static let cardFields = "summary,status,issuetype,priority,assignee,labels,updated"

    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    func myName() async throws -> String? {
        (try await get("/rest/api/2/myself") as? [String: Any])?["displayName"] as? String
    }

    func boards() async throws -> [JiraBoardInfo] {
        var out: [JiraBoardInfo] = []
        var start = 0
        while true {
            let object = try await get("/rest/agile/1.0/board?startAt=\(start)&maxResults=50") as? [String: Any] ?? [:]
            let values = object["values"] as? [[String: Any]] ?? []
            out += values.compactMap { value in
                guard let id = value["id"] as? Int, let name = value["name"] as? String else { return nil }
                return JiraBoardInfo(id: id, name: name, type: value["type"] as? String ?? "", projectKey: (value["location"] as? [String: Any])?["projectKey"] as? String)
            }
            start += values.count
            if values.isEmpty || object["isLast"] as? Bool == true || start >= 500 { break }
        }
        return out
    }

    func columns(board: Int) async throws -> [JiraColumnInfo] {
        let object = try await get("/rest/agile/1.0/board/\(board)/configuration") as? [String: Any] ?? [:]
        let columns = (object["columnConfig"] as? [String: Any])?["columns"] as? [[String: Any]] ?? []
        return columns.compactMap { column in
            guard let name = column["name"] as? String else { return nil }
            let ids = (column["statuses"] as? [[String: Any]] ?? []).compactMap { ($0["id"] as? String) ?? ($0["id"] as? Int).map(String.init) }
            return JiraColumnInfo(name: name, statusIDs: ids)
        }
        .filter { !$0.statusIDs.isEmpty }
    }

    func sprints(board: Int, states: String) async throws -> [JiraSprintInfo] {
        let object = try await get("/rest/agile/1.0/board/\(board)/sprint?state=\(states)&maxResults=50") as? [String: Any] ?? [:]
        return (object["values"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = value["id"] as? Int, let name = value["name"] as? String else { return nil }
            let end = (value["endDate"] as? String).flatMap(Self.parseDate)
            return JiraSprintInfo(id: id, name: name, state: value["state"] as? String ?? "", endDate: end)
        }
    }

    func cards(_ path: String, jql: String? = nil, start: Int = 0, limit: Int = 500) async throws -> (cards: [JiraCard], total: Int) {
        var query = "fields=\(Self.cardFields)"
        if let jql { query += "&jql=" + Self.encode(jql) }
        var out: [JiraCard] = []
        var offset = start
        var total = 0
        while out.count < limit {
            let page = min(100, limit - out.count)
            let object = try await get("\(path)?\(query)&startAt=\(offset)&maxResults=\(page)") as? [String: Any] ?? [:]
            let issues = object["issues"] as? [[String: Any]] ?? []
            out += issues.compactMap(parseCard)
            offset += issues.count
            total = object["total"] as? Int ?? offset
            if issues.isEmpty || offset >= total { break }
        }
        return (out, total)
    }

    func moves(_ key: String) async throws -> [JiraMove] {
        let object = try await get("/rest/api/2/issue/\(key)/transitions") as? [String: Any] ?? [:]
        return (object["transitions"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            let to = item["to"] as? [String: Any]
            return JiraMove(
                id: id,
                name: name,
                toID: to?["id"] as? String,
                toName: to?["name"] as? String ?? name,
                toCategory: (to?["statusCategory"] as? [String: Any])?["key"] as? String ?? "new"
            )
        }
    }

    func move(_ key: String, transition: String) async throws {
        try await send("/rest/api/2/issue/\(key)/transitions", method: "POST", body: ["transition": ["id": transition]])
    }

    func parseCard(_ root: [String: Any]) -> JiraCard? {
        guard let key = root["key"] as? String, let fields = root["fields"] as? [String: Any] else { return nil }
        let status = fields["status"] as? [String: Any]
        return JiraCard(
            key: key,
            summary: fields["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            statusID: (status?["id"] as? String) ?? (status?["id"] as? Int).map(String.init),
            statusCategory: (status?["statusCategory"] as? [String: Any])?["key"] as? String ?? "new",
            type: (fields["issuetype"] as? [String: Any])?["name"] as? String,
            priority: (fields["priority"] as? [String: Any])?["name"] as? String,
            assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String,
            labels: fields["labels"] as? [String] ?? [],
            updated: (fields["updated"] as? String).flatMap(Self.parseDate),
            url: base.appendingPathComponent("browse").appendingPathComponent(key)
        )
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return fallback.date(from: text)
    }
}

@MainActor
final class JiraBoardStore: ObservableObject {
    static let shared = JiraBoardStore()
    static let unassigned = "\u{0}unassigned"

    @Published private(set) var siteID: String?
    @Published private(set) var boards: [JiraBoardInfo] = []
    @Published private(set) var board: JiraBoardInfo?
    @Published private(set) var columns: [JiraColumnInfo] = []
    @Published private(set) var sprint: JiraSprintInfo?
    @Published private(set) var sprintCards: [JiraCard] = []
    @Published private(set) var backlog: [JiraBacklogGroup] = []
    @Published private(set) var list: [JiraCard] = []
    @Published private(set) var listTotal = 0
    @Published private(set) var me: String?
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published private(set) var loadedSprint = false
    @Published private(set) var loadedBacklog = false
    @Published private(set) var loadedList = false
    @Published private(set) var moving: Set<String> = []
    @Published var error: String?

    private let defaults = UserDefaults.standard
    private var generation = 0
    let isDemo = ProcessInfo.processInfo.arguments.contains("-PYDemo")

    private init() {
        siteID = defaults.string(forKey: "jira.board.site")
        if isDemo { loadDemo() }
    }

    private func loadDemo() {
        let base = URL(string: "https://example.atlassian.net/browse")!
        func card(_ number: Int, _ summary: String, _ status: String, _ id: String, _ category: String, _ type: String, _ priority: String, _ assignee: String?, _ labels: [String] = []) -> JiraCard {
            JiraCard(key: "COM-\(number)", summary: summary, status: status, statusID: id, statusCategory: category, type: type, priority: priority, assignee: assignee, labels: labels, updated: Date().addingTimeInterval(-Double(number) * 60), url: base.appendingPathComponent("COM-\(number)"))
        }
        let demo = JiraBoardInfo(id: 1, name: "Companion", type: "scrum", projectKey: "COM")
        boards = [demo, JiraBoardInfo(id: 2, name: "Platform", type: "kanban", projectKey: "PLT")]
        board = demo
        me = "Alex Rivera"
        columns = [
            JiraColumnInfo(name: "To Do", statusIDs: ["1"]),
            JiraColumnInfo(name: "In Progress", statusIDs: ["2"]),
            JiraColumnInfo(name: "Code Review", statusIDs: ["3"]),
            JiraColumnInfo(name: "Done", statusIDs: ["4"])
        ]
        sprint = JiraSprintInfo(id: 7, name: "Sprint 7", state: "active", endDate: Date().addingTimeInterval(86400 * 5))
        sprintCards = [
            card(2383, "Users can repost posts with attached services and tours", "In Progress", "2", "indeterminate", "Story", "Medium", "Alex Rivera", ["frontend"]),
            card(2417, "First cash out is limited to 200 dollars", "In Progress", "2", "indeterminate", "Story", "High", "Alex Rivera"),
            card(2288, "Previous dates cannot be selected in the All services calendar", "To Do", "1", "new", "Bug", "Low", "Alex Rivera", ["calendar", "frontend", "regression"]),
            card(2274, "Views and age are not displayed on multimedia posts", "Code Review", "3", "indeterminate", "Bug", "Lowest", "Sam Okafor"),
            card(2188, "Incorrect error message when deleting a service with bookings", "Code Review", "3", "indeterminate", "Bug", "Medium", "Alex Rivera"),
            card(2101, "Booking confirmation email shows the wrong time zone", "Done", "4", "done", "Bug", "High", "Sam Okafor"),
            card(2090, "Host onboarding checklist", "To Do", "1", "new", "Task", "Medium", nil)
        ]
        backlog = [
            JiraBacklogGroup(id: "sprint.7", title: "Sprint 7", subtitle: nil, active: true, cards: sprintCards),
            JiraBacklogGroup(id: "sprint.8", title: "Sprint 8", subtitle: nil, active: false, cards: [card(2450, "Tour drafts autosave", "To Do", "1", "new", "Story", "Medium", "Alex Rivera")]),
            JiraBacklogGroup(id: "backlog", title: "Backlog", subtitle: nil, active: false, cards: [card(2501, "Export bookings to CSV", "To Do", "1", "new", "Task", "Low", nil), card(2502, "Dark mode for the public profile", "To Do", "1", "new", "Story", "Low", "Sam Okafor")])
        ]
        list = sprintCards + backlog[1].cards + backlog[2].cards
        listTotal = list.count
        loadedSprint = true
        loadedBacklog = true
        loadedList = true
    }

    private var site: JiraSite? {
        let sites = JiraStore.shared.sites
        return sites.first { $0.id == siteID } ?? sites.first
    }

    private var client: JiraREST? { site.flatMap(JiraStore.shared.client) }

    var siteName: String { site?.name ?? "Jira" }

    func select(site id: String) {
        guard id != siteID else { return }
        siteID = id
        defaults.set(id, forKey: "jira.board.site")
        reset()
        boards = []
        board = nil
        me = nil
    }

    func select(board next: JiraBoardInfo) {
        guard next.id != board?.id, let site else { return }
        board = next
        defaults.set(next.id, forKey: "jira.board.selected.\(site.id)")
        reset()
    }

    private func reset() {
        generation += 1
        columns = []
        sprint = nil
        sprintCards = []
        backlog = []
        list = []
        listTotal = 0
        loadedSprint = false
        loadedBacklog = false
        loadedList = false
        error = nil
    }

    func load(_ tab: JiraBoardTab, force: Bool = false) async {
        guard !isDemo, let client, let site else { return }
        let token = generation
        loading = true
        defer { if token == generation { loading = false } }
        do {
            if boards.isEmpty || force {
                async let who = try? client.myName()
                let all = try await client.boards().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let name = await who
                guard token == generation else { return }
                boards = all
                if let name { me = name }
                let saved = defaults.integer(forKey: "jira.board.selected.\(site.id)")
                let mine = Set(site.projectKeys)
                board = all.first { $0.id == board?.id }
                    ?? all.first { $0.id == saved }
                    ?? all.first { $0.isScrum && $0.projectKey.map(mine.contains) == true }
                    ?? all.first { $0.isScrum }
                    ?? all.first
            }
            guard let board else {
                loadedSprint = true
                loadedBacklog = true
                loadedList = true
                return
            }
            switch tab {
            case .sprint:
                guard force || !loadedSprint else { return }
                async let config = try? client.columns(board: board.id)
                let active = board.isScrum ? ((try? await client.sprints(board: board.id, states: "active")) ?? []).first : nil
                let cards: [JiraCard]
                if let active {
                    cards = try await client.cards("/rest/agile/1.0/board/\(board.id)/sprint/\(active.id)/issue").cards
                } else {
                    cards = try await client.cards("/rest/agile/1.0/board/\(board.id)/issue", jql: "statusCategory != Done OR updated >= -14d").cards
                }
                let loadedColumns = await config ?? []
                guard token == generation else { return }
                columns = loadedColumns
                sprint = active
                sprintCards = cards
                loadedSprint = true
            case .backlog:
                guard force || !loadedBacklog else { return }
                var groups: [JiraBacklogGroup] = []
                if board.isScrum {
                    let sprints = (try? await client.sprints(board: board.id, states: "active,future")) ?? []
                    for item in sprints {
                        let cards = try await client.cards("/rest/agile/1.0/board/\(board.id)/sprint/\(item.id)/issue").cards
                        let ends = item.endDate.map { String(format: L("Ends %@"), $0.formatted(date: .abbreviated, time: .omitted)) }
                        groups.append(JiraBacklogGroup(id: "sprint.\(item.id)", title: item.name, subtitle: ends, active: item.state == "active", cards: cards))
                    }
                }
                let rest = try await client.cards("/rest/agile/1.0/board/\(board.id)/backlog").cards
                groups.append(JiraBacklogGroup(id: "backlog", title: L("Backlog"), subtitle: nil, active: false, cards: rest))
                guard token == generation else { return }
                backlog = groups
                loadedBacklog = true
            case .list:
                guard force || !loadedList else { return }
                let page = try await client.cards("/rest/agile/1.0/board/\(board.id)/issue", jql: "ORDER BY updated DESC", limit: 50)
                guard token == generation else { return }
                list = page.cards
                listTotal = page.total
                loadedList = true
            }
            error = nil
        } catch {
            guard token == generation, !Self.isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }

    var hasMoreList: Bool { list.count < listTotal }

    func loadMoreList() async {
        guard let client, let board, hasMoreList, !loadingMore else { return }
        let token = generation
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.cards("/rest/agile/1.0/board/\(board.id)/issue", jql: "ORDER BY updated DESC", start: list.count, limit: 50)
            guard token == generation else { return }
            let known = Set(list.map(\.key))
            list += page.cards.filter { !known.contains($0.key) }
            listTotal = page.total
        } catch {
            if !Self.isCancellation(error) { self.error = error.localizedDescription }
        }
    }

    func move(_ card: JiraCard, to column: JiraColumnInfo) async -> Bool {
        guard card.statusID.map(column.statusIDs.contains) != true else { return true }
        let options = await moves(for: card)
        guard let move = options.first(where: { $0.toID.map(column.statusIDs.contains) == true }) else {
            error = String(format: L("%@ can't move to %@ from %@ — the workflow has no such transition."), card.key, column.name, card.status)
            return false
        }
        return await apply(move, to: card)
    }

    func moves(for card: JiraCard) async -> [JiraMove] {
        if isDemo {
            return zip(columns, ["new", "indeterminate", "indeterminate", "done"]).map { column, category in
                JiraMove(id: column.statusIDs[0], name: column.name, toID: column.statusIDs[0], toName: column.name, toCategory: category)
            }
        }
        guard let client else { return [] }
        return (try? await client.moves(card.key)) ?? []
    }

    func apply(_ move: JiraMove, to card: JiraCard) async -> Bool {
        guard isDemo || client != nil else { return false }
        moving.insert(card.key)
        defer { moving.remove(card.key) }
        do {
            if let client, !isDemo { try await client.move(card.key, transition: move.id) }
            update(card.key) { item in
                item.status = move.toName
                item.statusID = move.toID
                item.statusCategory = move.toCategory
            }
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func update(_ key: String, _ change: (inout JiraCard) -> Void) {
        if let index = sprintCards.firstIndex(where: { $0.key == key }) { change(&sprintCards[index]) }
        if let index = list.firstIndex(where: { $0.key == key }) { change(&list[index]) }
        for group in backlog.indices {
            if let index = backlog[group].cards.firstIndex(where: { $0.key == key }) { change(&backlog[group].cards[index]) }
        }
    }

    func card(_ key: String) -> JiraCard? {
        sprintCards.first { $0.key == key } ?? list.first { $0.key == key } ?? backlog.lazy.flatMap(\.cards).first { $0.key == key }
    }

    func grouped(_ cards: [JiraCard]) -> [(column: JiraColumnInfo, cards: [JiraCard])] {
        if columns.isEmpty {
            var order: [String] = []
            var byStatus: [String: [JiraCard]] = [:]
            for card in cards {
                if byStatus[card.status] == nil { order.append(card.status) }
                byStatus[card.status, default: []].append(card)
            }
            return order.map { (JiraColumnInfo(name: $0, statusIDs: []), byStatus[$0] ?? []) }
        }
        return columns.map { column in (column, cards.filter { $0.statusID.map(column.statusIDs.contains) == true }) }
    }
}
