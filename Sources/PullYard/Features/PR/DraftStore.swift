import Foundation

struct SavedReviewDraft: Codable, Equatable {
    struct Comment: Codable, Equatable {
        var path: String
        var line: Int
        var side: String
        var body: String
    }

    var pending: [Comment] = []
    var composer: Comment?
    var replies: [String: String] = [:]
    var comment = ""
    var summary = ""

    var isEmpty: Bool {
        pending.isEmpty && (composer?.body.isBlank ?? true) && replies.values.allSatisfy(\.isBlank) && comment.isBlank && summary.isBlank
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
final class DraftStore {
    static let shared = DraftStore(directory: NSClassFromString("XCTestCase") == nil ? defaultDirectory : nil)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PullYard", isDirectory: true)
            .appendingPathComponent("drafts", isDirectory: true)
    }

    private let directory: URL?
    private var memory: [String: Data] = [:]

    init(directory: URL?) {
        self.directory = directory
    }

    nonisolated static func key(account: String?, host: String, repo: String, number: Int, kind: String = "pr") -> String {
        "\(kind)|\(account ?? "-")|\(host)|\(repo)#\(number)"
    }

    private func file(_ key: String) -> URL? {
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return directory?.appendingPathComponent(name + ".json")
    }

    private func read(_ key: String) -> Data? {
        if let file = file(key) { return try? Data(contentsOf: file) }
        return memory[key]
    }

    private func write(_ data: Data?, _ key: String) {
        guard let file = file(key) else {
            memory[key] = data
            return
        }
        guard let data else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func review(_ key: String) -> SavedReviewDraft? {
        read(key).flatMap { try? JSONDecoder().decode(SavedReviewDraft.self, from: $0) }
    }

    func save(_ draft: SavedReviewDraft, key: String) {
        write(draft.isEmpty ? nil : try? JSONEncoder().encode(draft), key)
    }

    func text(_ key: String) -> String {
        read(key).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    func setText(_ text: String, key: String) {
        write(text.isBlank ? nil : Data(text.utf8), key)
    }
}
