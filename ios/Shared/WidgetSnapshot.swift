import Foundation

struct WidgetItem: Codable, Hashable, Identifiable {
    let repo: String
    let number: Int
    let title: String
    let author: String?
    let ci: String?
    var id: String { "\(repo)#\(number)" }
    var url: URL? { URL(string: "pullyard://pull/\(repo)/\(number)") }
}

struct WidgetSnapshot: Codable, Hashable {
    var updated: Date
    var needsReview: Int
    var myOpen: Int
    var unread: Int
    var items: [WidgetItem]

    static let groupID = "group.com.pullyard.mobile"
    static let fileName = "widget-snapshot.json"

    static var placeholder: WidgetSnapshot {
        WidgetSnapshot(updated: .now, needsReview: 3, myOpen: 2, unread: 5, items: [
            WidgetItem(repo: "harbor/api", number: 482, title: "Add ETag support to repository sync", author: "mira-dev", ci: "SUCCESS"),
            WidgetItem(repo: "harbor/mobile", number: 1290, title: "Fix cold start when offline", author: "alex-k", ci: "FAILURE"),
            WidgetItem(repo: "harbor/design", number: 77, title: "New status colours", author: "sam-ui", ci: "PENDING"),
        ])
    }

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
