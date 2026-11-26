import Foundation

struct LocalStore {
    let directory: URL?

    static let cache = LocalStore(base: .cachesDirectory)
    static let support = LocalStore(base: .applicationSupportDirectory)

    init(base: FileManager.SearchPathDirectory) {
        directory = FileManager.default.urls(for: base, in: .userDomainMask).first?.appendingPathComponent("PullYard", isDirectory: true)
    }

    init(directory: URL?) {
        self.directory = directory
    }

    func read(_ name: String) -> Data? {
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    func write(_ data: Data, as name: String) {
        guard var directory else { return }
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? directory.setResourceValues(values)
            }
            let target = directory.appendingPathComponent(name)
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return
        }
    }

    func remove(_ name: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func readJSON<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = read(name) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    func writeJSON<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        write(data, as: name)
    }
}

struct DraftKey: Hashable {
    enum Kind: Hashable {
        case comment
        case review(ReviewEvent)
        case reply(Int)
        case pendingReview(Int)
    }
    let pull: PRKey
    let kind: Kind

    var storageName: String {
        let suffix: String
        switch kind {
        case .comment: suffix = "comment"
        case let .review(event): suffix = "review-\(event.rawValue.lowercased())"
        case let .reply(id): suffix = "reply-\(id)"
        case let .pendingReview(id): suffix = "pending-\(id)"
        }
        return "\(pull.repo)#\(pull.number)|\(suffix)"
    }
}

final class DraftStore {
    static let shared = DraftStore()
    private let store: LocalStore
    private let fileName = "drafts.json"
    private var drafts: [String: String]

    init(store: LocalStore = .support) {
        self.store = store
        drafts = store.readJSON([String: String].self, fileName) ?? [:]
    }

    func text(for key: DraftKey) -> String { drafts[key.storageName] ?? "" }

    func save(_ text: String, for key: DraftKey) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { drafts[key.storageName] = nil } else { drafts[key.storageName] = text }
        store.writeJSON(drafts, fileName)
    }

    func clear(_ key: DraftKey) { save("", for: key) }

    func clearAll() {
        drafts = [:]
        store.remove(fileName)
    }
}

struct AccountPreferences {
    let login: String
    let defaults: UserDefaults

    init(login: String, defaults: UserDefaults = .standard) {
        self.login = login.lowercased()
        self.defaults = defaults
    }

    private func key(_ name: String) -> String { "mobile.account.\(login).\(name)" }

    var selectedProject: String {
        get { defaults.string(forKey: key("selectedProject")) ?? "" }
        nonmutating set { defaults.set(newValue, forKey: key("selectedProject")) }
    }
    var projectOrder: [String] {
        get { defaults.stringArray(forKey: key("projectOrder")) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: key("projectOrder")) }
    }
    var savedSearches: [String] {
        get { defaults.stringArray(forKey: key("savedSearches")) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: key("savedSearches")) }
    }
    var pinnedProjects: [String] {
        get { defaults.stringArray(forKey: key("pinnedProjects")) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: key("pinnedProjects")) }
    }
    func statusFilter(for queue: PRQueue) -> PRStatusFilter {
        defaults.string(forKey: key("status.\(queue.rawValue)")).flatMap(PRStatusFilter.init(rawValue:)) ?? .open
    }
    func setStatusFilter(_ filter: PRStatusFilter, for queue: PRQueue) {
        defaults.set(filter.rawValue, forKey: key("status.\(queue.rawValue)"))
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix("mobile.account.") {
            defaults.removeObject(forKey: name)
        }
    }
}
