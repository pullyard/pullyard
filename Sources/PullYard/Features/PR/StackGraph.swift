import Foundation
import SwiftUI

struct StackNode: Codable, Hashable, Identifiable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let headRepo: String?
    let author: String?
    let updatedAt: Date?
    let reviewDecision: String?
    let ci: String?
    let commitOid: String?
    let commitHeadline: String?

    var id: Int { number }
    var visualState: VisualState { .pr(state: state, draft: isDraft) }
    var status: StackStatus { StackStatus(self) }
    var jiraKey: String? { StackNode.jiraKey(in: headRefName) ?? StackNode.jiraKey(in: title) }

    func merging(_ fresh: StackNode) -> StackNode {
        StackNode(number: number, title: fresh.title, state: fresh.state, isDraft: fresh.isDraft,
                  headRefName: fresh.headRefName, baseRefName: fresh.baseRefName, headRepo: fresh.headRepo ?? headRepo,
                  author: fresh.author ?? author, updatedAt: fresh.updatedAt ?? updatedAt,
                  reviewDecision: fresh.reviewDecision ?? reviewDecision, ci: fresh.ci ?? ci,
                  commitOid: fresh.commitOid ?? commitOid, commitHeadline: fresh.commitHeadline ?? commitHeadline)
    }

    private static let jiraPattern = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])[A-Z][A-Z0-9]+-[0-9]+(?![0-9])")

    static func jiraKey(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = jiraPattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}

enum StackStatus: Equatable {
    case merged, closed, draft, ciFailed, changesRequested, ready, checking, review

    init(_ n: StackNode) {
        switch n.state {
        case "MERGED": self = .merged
        case "CLOSED": self = .closed
        default:
            if n.isDraft { self = .draft }
            else if n.ci == "FAILURE" || n.ci == "ERROR" { self = .ciFailed }
            else if n.reviewDecision == "CHANGES_REQUESTED" { self = .changesRequested }
            else if n.ci == "PENDING" || n.ci == "EXPECTED" { self = .checking }
            else if n.reviewDecision == "APPROVED" { self = .ready }
            else { self = .review }
        }
    }

    var title: String {
        switch self {
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .draft: return "Draft"
        case .ciFailed: return "CI failed"
        case .changesRequested: return "Changes requested"
        case .ready: return "Ready"
        case .checking: return "Checks running"
        case .review: return "In review"
        }
    }

    var color: Color {
        switch self {
        case .merged: return .ghPurple
        case .closed, .ciFailed, .changesRequested: return .syRed
        case .draft: return .sySlate
        case .ready: return .syGreen
        case .checking, .review: return .syAmber
        }
    }
}

struct StackTree: Equatable {
    let base: String
    let current: Int
    let nodes: [Int: StackNode]
    let parent: [Int: Int]
    let children: [Int: [Int]]
    let root: Int

    var count: Int { nodes.count }

    var line: [StackNode] {
        var up: [Int] = []
        var n: Int? = current
        while let x = n {
            up.insert(x, at: 0)
            n = parent[x]
        }
        var down = current
        while let next = children[down]?.first {
            up.append(next)
            down = next
        }
        return up.compactMap { nodes[$0] }
    }

    var pathSet: Set<Int> {
        var out: Set<Int> = []
        var n: Int? = current
        while let x = n {
            out.insert(x)
            n = parent[x]
        }
        var stack = children[current] ?? []
        while let x = stack.popLast() {
            out.insert(x)
            stack += children[x] ?? []
        }
        return out
    }

    func onPath(_ number: Int) -> Bool {
        pathSet.contains(number)
    }

    static func build(current: StackNode, open: [StackNode], repo: String, limit: Int = 60) -> StackTree? {
        var all: [Int: StackNode] = [:]
        for n in open { all[n.number] = n }
        all[current.number] = all[current.number].map { $0.merging(current) } ?? current

        let repoKey = repo.lowercased()
        var owner: [String: StackNode] = [:]
        func preferred(_ a: StackNode, over b: StackNode) -> Bool {
            if a.number == current.number || b.number == current.number { return a.number == current.number }
            let da = a.updatedAt ?? .distantPast, db = b.updatedAt ?? .distantPast
            return da == db ? a.number > b.number : da > db
        }
        for n in all.values {
            guard n.headRepo?.lowercased() == repoKey, n.state == "OPEN" || n.number == current.number else { continue }
            if let existing = owner[n.headRefName], !preferred(n, over: existing) { continue }
            owner[n.headRefName] = n
        }

        func parentOf(_ n: StackNode) -> StackNode? {
            guard let p = owner[n.baseRefName], p.number != n.number else { return nil }
            return p
        }

        var kids: [Int: [Int]] = [:]
        for n in all.values {
            if let p = parentOf(n) { kids[p.number, default: []].append(n.number) }
        }
        for k in kids.keys { kids[k]?.sort() }

        var path: [Int] = [current.number]
        var seen: Set<Int> = [current.number]
        var top = all[current.number]!
        while let p = parentOf(top), seen.insert(p.number).inserted {
            path.insert(p.number, at: 0)
            top = p
        }

        var included = Set(path)
        var queue = [top.number]
        var queued: Set<Int> = [top.number]
        var i = 0
        while i < queue.count {
            let x = queue[i]
            i += 1
            for c in kids[x] ?? [] where !queued.contains(c) {
                guard included.contains(c) || included.count < limit else { continue }
                included.insert(c)
                queued.insert(c)
                queue.append(c)
            }
        }
        guard included.count > 1 else { return nil }

        var nodes: [Int: StackNode] = [:]
        var parent: [Int: Int] = [:]
        var children: [Int: [Int]] = [:]
        for x in included {
            nodes[x] = all[x]
            if x != top.number, let p = parentOf(all[x]!), included.contains(p.number) { parent[x] = p.number }
            let cs = (kids[x] ?? []).filter { included.contains($0) && $0 != top.number }
            if !cs.isEmpty { children[x] = cs }
        }
        return StackTree(base: top.baseRefName, current: current.number, nodes: nodes, parent: parent, children: children, root: top.number)
    }
}

struct StackLayout: Equatable {
    struct Slot: Equatable {
        let column: Double
        let level: Int
    }

    let slots: [Int: Slot]
    let columns: Int
    let levels: Int

    init(_ tree: StackTree) {
        var slots: [Int: Slot] = [:]
        var next = 0
        var depth = 0
        func place(_ n: Int, _ level: Int) {
            depth = max(depth, level)
            let cs = tree.children[n] ?? []
            if cs.isEmpty {
                slots[n] = Slot(column: Double(next), level: level)
                next += 1
                return
            }
            for c in cs { place(c, level + 1) }
            let cols = cs.compactMap { slots[$0]?.column }
            slots[n] = Slot(column: ((cols.min() ?? 0) + (cols.max() ?? 0)) / 2, level: level)
        }
        place(tree.root, 1)
        self.slots = slots
        self.columns = max(next, 1)
        self.levels = depth
    }
}
