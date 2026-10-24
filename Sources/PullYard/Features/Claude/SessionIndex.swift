import CryptoKit
import Foundation

actor SessionIndex {
    static let shared = SessionIndex()

    private let dir: URL
    private var stamps: [String: String] = [:]
    private var loaded = false

    init(directory: URL? = nil) {
        dir = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PullYard/session-index", isDirectory: true)
    }

    private var stampsFile: URL { dir.appendingPathComponent("stamps.json") }

    private func load() {
        guard !loaded else { return }
        loaded = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: stampsFile), let s = try? JSONDecoder().decode([String: String].self, from: data) { stamps = s }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stamps) { try? data.write(to: stampsFile, options: .atomic) }
    }

    nonisolated static func key(_ file: URL) -> String {
        SHA256.hash(data: Data(file.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func stamp(_ file: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              let m = a[.modificationDate] as? Date, let size = a[.size] as? NSNumber else { return nil }
        return "\(Int(m.timeIntervalSince1970))-\(size.intValue)"
    }

    func update(_ files: [URL]) {
        load()
        var changed = false
        for file in files {
            guard let st = stamp(file), stamps[file.path] != st else { continue }
            let text = Self.extract(file)
            try? Data(text.utf8).write(to: dir.appendingPathComponent(Self.key(file) + ".txt"), options: .atomic)
            stamps[file.path] = st
            changed = true
        }
        if changed { save() }
    }

    func search(_ query: String, files: [URL]) -> [String: String] {
        update(files)
        let needle = query.lowercased()
        var out: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.key(file) + ".txt")) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard let r = text.range(of: needle) else { continue }
            out[file.path] = Self.snippet(text, around: r)
        }
        return out
    }

    nonisolated static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        let start = text.index(r.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 70, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }

    nonisolated static func extract(_ file: URL) -> String {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "" }
        let user = Data("\"type\":\"user\"".utf8), assistant = Data("\"type\":\"assistant\"".utf8), toolResult = Data("\"tool_use_id\"".utf8)
        var parts: [String] = []
        for line in data.split(separator: 0x0A) where line.count < 400_000 {
            let isUser = line.range(of: user) != nil
            guard isUser || line.range(of: assistant) != nil else { continue }
            if isUser && line.range(of: toolResult) != nil { continue }
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if isUser {
                if let t = SessionRewind.promptText(o) { parts.append(t) }
            } else if let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for b in blocks where b["type"] as? String == "text" {
                    if let t = b["text"] as? String, !t.isEmpty { parts.append(t) }
                }
            }
        }
        return parts.joined(separator: "\n").lowercased()
    }
}
