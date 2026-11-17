import Foundation

struct SavedPrompt: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var text: String
}

@Observable
@MainActor
final class PromptLibrary {
    static let shared = PromptLibrary()

    private let store: UserDefaults
    private let key = "agents.savedPrompts"
    private(set) var prompts: [SavedPrompt] = []

    init(store: UserDefaults = .standard) {
        self.store = store
        if let data = store.data(forKey: key), let saved = try? JSONDecoder().decode([SavedPrompt].self, from: data) {
            prompts = saved
        }
    }

    nonisolated static func title(for text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    @discardableResult
    func add(text raw: String, title: String? = nil) -> SavedPrompt? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let existing = prompts.first(where: { $0.text == text }) { return existing }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = SavedPrompt(title: name.isEmpty ? Self.title(for: text) : name, text: text)
        prompts.append(prompt)
        save()
        return prompt
    }

    func update(_ prompt: SavedPrompt) {
        guard let i = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        prompts[i] = prompt
        save()
    }

    func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prompts) { store.set(data, forKey: key) }
    }
}
