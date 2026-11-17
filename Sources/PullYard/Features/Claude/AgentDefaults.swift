import Foundation

struct AgentModelChoice: Identifiable, Hashable, Codable {
    let value: String
    let displayName: String
    let description: String
    var id: String { value }
}

@Observable
@MainActor
final class AgentDefaults {
    static let shared = AgentDefaults()

    private enum Key {
        static let model = "claude.model"
        static let effort = "claude.effort"
        static let mode = "claude.mode"
        static let kind = "claude.ui"
        static let idle = "claude.idleSleepMinutes"
        static let remember = "claude.rememberComposerChoice"
        static let knownModels = "claude.knownModels"
        static let restoreTabs = "claude.restoreTabs"
        static let confirmQuit = "claude.confirmQuit"
    }

    private let store: UserDefaults

    var model: String { didSet { store.set(model, forKey: Key.model) } }
    var effort: ClaudeEffort { didSet { store.set(effort.rawValue, forKey: Key.effort) } }
    var mode: ClaudeMode { didSet { store.set(mode.rawValue, forKey: Key.mode) } }
    var kind: ClaudeTabKind { didSet { store.set(kind.rawValue, forKey: Key.kind) } }
    var idleMinutes: Int { didSet { store.set(idleMinutes, forKey: Key.idle) } }
    var rememberComposerChoice: Bool { didSet { store.set(rememberComposerChoice, forKey: Key.remember) } }
    var restoreTabs: Bool { didSet { store.set(restoreTabs, forKey: Key.restoreTabs) } }
    var confirmQuit: Bool { didSet { store.set(confirmQuit, forKey: Key.confirmQuit) } }
    private(set) var knownModels: [AgentModelChoice]

    init(store: UserDefaults = .standard) {
        self.store = store
        model = Self.normalizedModel(store.string(forKey: Key.model) ?? "")
        effort = ClaudeEffort(rawValue: store.string(forKey: Key.effort) ?? "") ?? .standard
        mode = ClaudeMode(rawValue: store.string(forKey: Key.mode) ?? "default") ?? .standard
        kind = ClaudeTabKind(rawValue: store.string(forKey: Key.kind) ?? "chat") ?? .chat
        idleMinutes = store.object(forKey: Key.idle) as? Int ?? 15
        rememberComposerChoice = store.bool(forKey: Key.remember)
        restoreTabs = store.object(forKey: Key.restoreTabs) as? Bool ?? true
        confirmQuit = store.object(forKey: Key.confirmQuit) as? Bool ?? true
        knownModels = (store.data(forKey: Key.knownModels)).flatMap { try? JSONDecoder().decode([AgentModelChoice].self, from: $0) } ?? []
    }

    var modelArgument: String? { model.isEmpty ? nil : model }
    var effortArgument: String? { effort == .standard ? nil : effort.rawValue }

    var modelChoices: [AgentModelChoice] {
        var list = knownModels.filter { $0.value != "default" && !$0.value.isEmpty }
        if list.isEmpty {
            list = ClaudeModelOption.allCases.filter { $0 != .standard }.map { AgentModelChoice(value: $0.rawValue, displayName: $0.title, description: "") }
        }
        if !model.isEmpty, !list.contains(where: { $0.value == model }) {
            list.append(AgentModelChoice(value: model, displayName: model, description: ""))
        }
        return list
    }

    var modelTitle: String {
        if model.isEmpty { return "Default" }
        return modelChoices.first { $0.value == model }?.displayName ?? model
    }

    func remember(models: [ChatModelOption]) {
        let next = models.map { AgentModelChoice(value: $0.value, displayName: $0.displayName, description: $0.description) }
        guard !next.isEmpty, next != knownModels else { return }
        knownModels = next
        if let data = try? JSONEncoder().encode(next) { store.set(data, forKey: Key.knownModels) }
    }

    func adopt(model value: String) { model = Self.normalizedModel(value) }

    func adopt(effort value: String) { effort = ClaudeEffort(rawValue: value) ?? .standard }

    func adopt(mode value: String) { mode = ClaudeMode(rawValue: value) ?? .standard }

    func composerChanged(model value: String) {
        guard rememberComposerChoice else { return }
        adopt(model: value)
    }

    func composerChanged(effort value: String) {
        guard rememberComposerChoice else { return }
        adopt(effort: value)
    }

    func composerChanged(mode value: String) {
        guard rememberComposerChoice else { return }
        adopt(mode: value)
    }

    func reset() {
        model = ""
        effort = .standard
        mode = .standard
        kind = .chat
        idleMinutes = 15
        rememberComposerChoice = false
        restoreTabs = true
        confirmQuit = true
    }

    private static func normalizedModel(_ value: String) -> String {
        value == "default" ? "" : value
    }
}
