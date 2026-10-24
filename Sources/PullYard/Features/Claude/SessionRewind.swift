import Foundation

enum SessionRewind {
    static func sessionFile(id: String, configDir: String?) -> URL? {
        var roots: [URL] = []
        if let configDir, !configDir.isEmpty { roots.append(URL(fileURLWithPath: configDir).appendingPathComponent("projects", isDirectory: true)) }
        roots.append(ClaudeSessionParser.root)
        let fm = FileManager.default
        for root in roots {
            guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                let file = dir.appendingPathComponent(id + ".jsonl")
                if fm.fileExists(atPath: file.path) { return file }
            }
        }
        return nil
    }

    static func promptText(_ o: [String: Any]) -> String? {
        guard o["type"] as? String == "user", o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true,
              o["isCompactSummary"] as? Bool != true, let msg = o["message"] as? [String: Any] else { return nil }
        let raw: String
        if let s = msg["content"] as? String {
            raw = s
        } else if let blocks = msg["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            let texts = blocks.compactMap { b -> String? in
                guard b["type"] as? String == "text", let s = b["text"] as? String, !s.hasPrefix("<") else { return nil }
                return s
            }
            guard !texts.isEmpty else { return nil }
            raw = texts.joined(separator: "\n")
        } else {
            return nil
        }
        guard case .user(_, let text, _)? = ChatSession.historyUserItem(id: "", text: raw) else { return nil }
        return text
    }

    static func cutIndex(lines: [Data], text: String, occurrenceFromEnd: Int) -> Int? {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = 0
        for i in lines.indices.reversed() {
            guard let o = try? JSONSerialization.jsonObject(with: lines[i]) as? [String: Any],
                  let t = promptText(o), t.trimmingCharacters(in: .whitespacesAndNewlines) == target else { continue }
            if seen == occurrenceFromEnd { return i }
            seen += 1
        }
        return nil
    }

    static func fork(file: URL, text: String, occurrenceFromEnd: Int) throws -> (id: String, file: URL) {
        let data = try Data(contentsOf: file)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        guard let cut = cutIndex(lines: lines, text: text, occurrenceFromEnd: occurrenceFromEnd) else {
            throw APIError(message: "Couldn't find this message in the session file")
        }
        let newID = UUID().uuidString.lowercased()
        var out = Data()
        for line in lines[..<cut] {
            guard var o = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if o["sessionId"] != nil { o["sessionId"] = newID }
            guard let encoded = try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]) else { continue }
            out.append(encoded)
            out.append(0x0A)
        }
        let target = file.deletingLastPathComponent().appendingPathComponent(newID + ".jsonl")
        try out.write(to: target, options: .atomic)
        return (newID, target)
    }
}
