import Foundation

/// Short, topical session titles, the way the Claude app names sessions:
/// a quick Haiku call on the first message, with a plain-text fallback.
enum SessionTitler {
    private static let instructions = """
    You name chat sessions. Reply with only a title for the user's request: 2 to 5 words, \
    in the same language as the request, sentence case, no quotes, no trailing punctuation.
    """

    /// Asks Claude (Haiku, no tools, no MCP, nothing saved) for a title.
    /// Returns nil if the CLI is missing, fails or takes too long.
    @MainActor
    static func title(for prompt: String, configDir: String?) async -> String? {
        guard let bin = ClaudeLauncher.claudeBinary else { return nil }
        let request = String(prompt.prefix(2000))
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["-p", "--model", "haiku", "--output-format", "text",
                           "--no-session-persistence", "--tools", "", "--strict-mcp-config",
                           "--disable-slash-commands", "--system-prompt", instructions]
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key == "PULLYARD_TOKEN" || key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
            ClaudeProfiles.apply(configDir, to: &env)
            env["PATH"] = [(bin as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            p.environment = env
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            input.fileHandleForWriting.write(Data(request.utf8))
            try? input.fileHandleForWriting.close()
            let deadline = DispatchTime.now() + 20
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: timer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            guard p.terminationStatus == 0 else { return nil }
            return clean(String(decoding: data, as: UTF8.self))
        }.value
    }

    static func clean(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.components(separatedBy: .newlines).first ?? t
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`«»“”*#. ").union(.whitespaces))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, t.count <= 60 else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// First words of the message, used when the model can't be reached.
    static func fallback(_ prompt: String) -> String {
        let words = prompt.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).joined(separator: " ")
        let t = String(words.prefix(48)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return t.isEmpty ? "New session" : t.prefix(1).uppercased() + t.dropFirst()
    }
}

/// Worktrees for new agent sessions, laid out like Claude Code's own:
/// `<repo>/.claude/worktrees/<topic>-<hex>` on branch `claude/<topic>-<hex>`,
/// branched from whatever the project has checked out.
enum SessionWorktree {
    static func isWorktree(_ folder: String) -> Bool {
        folder.contains("/.claude/worktrees/") || ProjectRoot.legacyWorktree(folder) != nil
    }

    /// True when `folder` is inside a git work tree that is not itself a worktree.
    static func canCreate(in folder: String) async -> Bool {
        guard !isWorktree(folder) else { return false }
        return await Task.detached(priority: .utility) {
            let r = Git.run(["rev-parse", "--is-inside-work-tree"], in: folder, timeout: 10)
            return r.ok && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }.value
    }

    /// Creates the worktree and returns the folder the session should run in
    /// (the same subfolder of the repo the session was opened on).
    static func create(from folder: String, title: String) async -> Result<String, Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            let top = Git.run(["rev-parse", "--show-toplevel"], in: folder, timeout: 10)
            let gitRoot = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard top.ok, !gitRoot.isEmpty else { return .failure(GitError(message: "\(folder) is not a git repository")) }
            // git reports the toplevel with symlinks resolved (/private/var/…); keep the
            // path the way the project was opened so the session groups under it.
            let opened = URL(fileURLWithPath: folder).standardizedFileURL
            let resolvedRoot = URL(fileURLWithPath: gitRoot).resolvingSymlinksInPath().standardizedFileURL.path
            let resolvedHere = opened.resolvingSymlinksInPath().path
            let rel = resolvedHere.hasPrefix(resolvedRoot + "/") ? String(resolvedHere.dropFirst(resolvedRoot.count + 1)) : ""
            var rootURL = opened
            for _ in rel.split(separator: "/") { rootURL.deleteLastPathComponent() }
            let root = rel.isEmpty || resolvedHere == resolvedRoot ? opened.path : rootURL.path
            let name = slug(title) + "-" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(6))
            let path = URL(fileURLWithPath: root).appendingPathComponent(PRWorktrees.folder).appendingPathComponent(name).path
            PRWorktrees.excludeFolder(in: root)
            let add = Git.run(["worktree", "add", "-b", "claude/" + name, path, "HEAD"], in: root, timeout: 120, mergeStderr: true)
            guard add.ok else {
                let message = add.out.trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(GitError(message: message.isEmpty ? "git worktree add failed" : message))
            }
            let target = rel.isEmpty ? path : path + "/" + rel
            return .success(FileManager.default.fileExists(atPath: target) ? target : path)
        }.value
    }

    /// "Fix login crash on iOS" → "fix-login-crash-on-ios". Non-Latin titles
    /// are transliterated; anything left empty becomes "session".
    static func slug(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? title
        let parts = latin.lowercased().split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let joined = parts.prefix(5).joined(separator: "-")
        let trimmed = String(joined.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }
}
