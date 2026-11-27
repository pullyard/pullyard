import Foundation
import Observation
import SwiftUI

/// One row the sidebar can show, before the user's order and names are applied.
struct SidebarItem: Identifiable {
    let section: SidebarSection
    let title: String
    let icon: String
    let color: Color
    var count = 0
    var group: String?

    var id: String { section.storageKey }
}

/// The user's sidebar customisation: the order of rows inside each group and
/// custom names for rows. Stored in UserDefaults, keyed by `SidebarSection.storageKey`
/// so it survives filters being added or removed.
@MainActor
@Observable
final class SidebarLayout {
    static let shared = SidebarLayout()

    private static let orderKey = "sidebar.order"
    private static let namesKey = "sidebar.names"
    private static let groupsKey = "sidebar.groupOrder"

    private let defaults: UserDefaults
    private(set) var order: [String: [String]]
    private(set) var names: [String: String]
    private(set) var groupOrder: [String]

    /// The row being renamed; the sidebar shows a rename prompt while it is set.
    var renaming: SidebarItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.dictionary(forKey: Self.orderKey) as? [String: [String]] ?? [:]
        names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        groupOrder = defaults.stringArray(forKey: Self.groupsKey) ?? []
    }

    // MARK: Names

    func title(for section: SidebarSection, default fallback: String) -> String {
        names[section.storageKey] ?? fallback
    }

    func hasCustomName(_ section: SidebarSection) -> Bool {
        names[section.storageKey] != nil
    }

    func rename(_ section: SidebarSection, to newName: String, default fallback: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == fallback {
            names[section.storageKey] = nil
        } else {
            names[section.storageKey] = trimmed
        }
        defaults.set(names, forKey: Self.namesKey)
    }

    func resetName(_ section: SidebarSection) {
        names[section.storageKey] = nil
        defaults.set(names, forKey: Self.namesKey)
    }

    // MARK: Order

    /// `items` in the user's saved order; rows the user never placed keep their default position at the end.
    func arranged(_ items: [SidebarItem], group: String) -> [SidebarItem] {
        guard let saved = order[group], !saved.isEmpty else { return items }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id] ?? saved.count + lhs.offset
            let r = rank[rhs.element.id] ?? saved.count + rhs.offset
            return l < r
        }.map(\.element)
    }

    func move(in group: String, visible: [SidebarItem], from source: IndexSet, to destination: Int) {
        var ids = visible.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        save(ids, group: group)
    }

    func canMove(_ item: SidebarItem, by delta: Int, in visible: [SidebarItem]) -> Bool {
        guard let i = visible.firstIndex(where: { $0.id == item.id }) else { return false }
        return visible.indices.contains(i + delta)
    }

    func move(_ item: SidebarItem, by delta: Int, in group: String, visible: [SidebarItem]) {
        var ids = visible.map(\.id)
        guard let i = ids.firstIndex(of: item.id), ids.indices.contains(i + delta) else { return }
        ids.swapAt(i, i + delta)
        save(ids, group: group)
    }

    /// Drag-and-drop: puts `id` where `target` is. Dragging down lands after the target, dragging up before it.
    @discardableResult
    func drop(item id: String, onto target: String, group: String, visible: [SidebarItem]) -> Bool {
        var ids = visible.map(\.id)
        guard id != target, let from = ids.firstIndex(of: id), let to = ids.firstIndex(of: target) else { return false }
        ids.remove(at: from)
        ids.insert(id, at: to)
        save(ids, group: group)
        return true
    }

    // MARK: Sections

    /// Drag-and-drop for whole sections, same rule as rows.
    @discardableResult
    func drop(group key: String, onto target: String, visible: [String]) -> Bool {
        var keys = visible
        guard key != target, let from = keys.firstIndex(of: key), let to = keys.firstIndex(of: target) else { return false }
        keys.remove(at: from)
        keys.insert(key, at: to)
        let hidden = groupOrder.filter { !keys.contains($0) }
        groupOrder = keys + hidden
        defaults.set(groupOrder, forKey: Self.groupsKey)
        return true
    }

    /// Section keys in the user's order; sections never placed keep their default position after the placed ones.
    func arrangedGroups(_ keys: [String]) -> [String] {
        guard !groupOrder.isEmpty else { return keys }
        let rank = Dictionary(groupOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return keys.enumerated().sorted { lhs, rhs in
            (rank[lhs.element] ?? groupOrder.count + lhs.offset) < (rank[rhs.element] ?? groupOrder.count + rhs.offset)
        }.map(\.element)
    }

    func canMoveGroup(_ key: String, by delta: Int, in visible: [String]) -> Bool {
        guard let i = visible.firstIndex(of: key) else { return false }
        return visible.indices.contains(i + delta)
    }

    func moveGroup(_ key: String, by delta: Int, in visible: [String]) {
        var keys = visible
        guard let i = keys.firstIndex(of: key), keys.indices.contains(i + delta) else { return }
        keys.swapAt(i, i + delta)
        let hidden = groupOrder.filter { !keys.contains($0) }
        groupOrder = keys + hidden
        defaults.set(groupOrder, forKey: Self.groupsKey)
    }

    var isCustomised: Bool { !order.isEmpty || !names.isEmpty || !groupOrder.isEmpty }

    func resetAll() {
        order = [:]
        names = [:]
        groupOrder = []
        defaults.removeObject(forKey: Self.groupsKey)
        defaults.removeObject(forKey: Self.orderKey)
        defaults.removeObject(forKey: Self.namesKey)
    }

    private func save(_ ids: [String], group: String) {
        // Keep ids of rows hidden right now (e.g. another provider's filters) after the visible ones.
        let hidden = (order[group] ?? []).filter { !ids.contains($0) }
        order[group] = ids + hidden
        defaults.set(order, forKey: Self.orderKey)
    }
}

/// What is being dragged in the sidebar, carried as a plain string so it works with `.draggable`.
enum SidebarDrag: Equatable {
    case row(group: String, id: String)
    case section(String)

    private static let prefix = "pullyard.sidebar|"

    var payload: String {
        switch self {
        case .row(let group, let id): return Self.prefix + "row|\(group)|\(id)"
        case .section(let key): return Self.prefix + "section|\(key)"
        }
    }

    init?(payload: String) {
        guard payload.hasPrefix(Self.prefix) else { return nil }
        let parts = payload.dropFirst(Self.prefix.count).split(separator: "|", maxSplits: 2).map(String.init)
        switch parts.first {
        case "row" where parts.count == 3: self = .row(group: parts[1], id: parts[2])
        case "section" where parts.count == 2: self = .section(parts[1])
        default: return nil
        }
    }
}
