import Foundation

/// Works out which git worktree an agent is really working in. A session starts in one folder,
/// but the agent may create a sibling worktree (`git worktree add ../repo-TICKET`) and keep
/// working there with `cd` or `git -C`; the session header should follow it.
enum ActiveWorktree {
    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "Read"]

    /// The most recent folder or file the agent touched, newest tool call first, as an absolute path.
    static func latestPath(in calls: [(name: String, input: [String: Any])], base: String) -> String? {
        for call in calls.reversed() {
            if fileTools.contains(call.name) {
                if let p = (call.input["file_path"] as? String) ?? (call.input["notebook_path"] as? String) {
                    return absolute(p, base: base)
                }
            } else if call.name == "Bash", let command = call.input["command"] as? String,
                      let dir = directory(in: command) {
                return absolute(dir, base: base)
            }
        }
        return nil
    }

    /// The last `cd <dir>` or `git -C <dir>` in a shell command.
    static func directory(in command: String) -> String? {
        let patterns = [
            #"(?:^|&&|;|\|\||\n|\()\s*cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))"#,
            #"\bgit\s+-C\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|)]+))"#,
        ]
        var best: (range: Range<String.Index>, path: String)?
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = command as NSString
            for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
                for g in 1...3 where m.range(at: g).location != NSNotFound {
                    guard let r = Range(m.range(at: g), in: command) else { continue }
                    if best == nil || r.lowerBound > best!.range.lowerBound { best = (r, String(command[r])) }
                }
            }
        }
        guard let path = best?.path, path != "-", !path.hasPrefix("$") else { return nil }
        return path
    }

    static func absolute(_ path: String, base: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let full = expanded.hasPrefix("/") ? expanded : (base as NSString).appendingPathComponent(expanded)
        return (full as NSString).standardizingPath
    }

    /// The top of the worktree holding `path`, if it belongs to the same repository as `sessionFolder`.
    static func worktreeRoot(of path: String, sessionFolder: String) -> String? {
        var dir = path
        var isDir: ObjCBool = false
        while !dir.isEmpty, dir != "/" {
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        guard dir.count > 1 else { return nil }
        let there = Git.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], in: dir, timeout: 5)
        let here = Git.run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], in: sessionFolder, timeout: 5)
        guard there.ok, here.ok else { return nil }
        let a = there.out.split(separator: "\n").map(String.init)
        let b = here.out.split(separator: "\n").map(String.init)
        guard a.count == 2, b.count == 2, a[1] == b[1] else { return nil }
        return a[0]
    }
}

extension ClaudeWorkspace {
    /// Points the tab's git view (header branch, changes, PRs) at the worktree the agent last worked in.
    func followActiveWorktree(_ tab: ClaudeTab) async {
        guard let chat = tab.chat else { return }
        let calls: [(name: String, input: [String: Any])] = chat.items.suffix(80).compactMap {
            if case .tool(let c) = $0 { return (c.name, c.input) }
            return nil
        }
        guard let path = ActiveWorktree.latestPath(in: calls, base: tab.git.path) else { return }
        let folder = tab.folder
        let root = await Task.detached(priority: .utility) { ActiveWorktree.worktreeRoot(of: path, sessionFolder: folder) }.value
        guard let root else { return }
        let sessionRoot = await Task.detached(priority: .utility) { ActiveWorktree.worktreeRoot(of: folder, sessionFolder: folder) }.value
        let target = root == sessionRoot ? folder : root
        guard target != tab.git.path else { return }
        tab.follow(git(for: target))
    }
}
