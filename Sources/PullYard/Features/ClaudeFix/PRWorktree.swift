import Foundation

struct PRWorktree: Equatable {
    let path: String
    let branch: String
    let remote: String
    let headOid: String
    let reused: Bool
    let dirty: Bool
}

struct GitError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PRWorktrees {
    static func path(clone: String, number: Int) -> String {
        let url = URL(fileURLWithPath: clone).standardizedFileURL
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + "-worktrees").appendingPathComponent("pr-\(number)").path
    }

    static func branch(number: Int) -> String { "pullyard/pr-\(number)" }

    @discardableResult
    static func git(_ args: [String], in dir: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message: "git \(args.first ?? "") failed: \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func remote(for repo: RepoRef, remotes: String) -> String? {
        let target = repo.full.lowercased()
        for line in remotes.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            var url = parts[1].lowercased()
            if url.hasSuffix(".git") { url.removeLast(4) }
            if url.hasSuffix("/" + target) || url.hasSuffix(":" + target) { return String(parts[0]) }
        }
        return nil
    }

    static func registered(_ porcelain: String) -> Set<String> {
        Set(porcelain.split(separator: "\n").compactMap { line in
            line.hasPrefix("worktree ") ? URL(fileURLWithPath: String(line.dropFirst(9))).standardizedFileURL.path : nil
        })
    }

    static func prepare(clone: String, repo: RepoRef, number: Int) throws -> PRWorktree {
        let remotes = (try? git(["remote", "-v"], in: clone)) ?? ""
        let remote = remote(for: repo, remotes: remotes) ?? "origin"
        try git(["fetch", "--quiet", remote, "pull/\(number)/head"], in: clone)
        let head = try git(["rev-parse", "FETCH_HEAD"], in: clone)
        let path = path(clone: clone, number: number)
        let branch = branch(number: number)
        let known = registered(try git(["worktree", "list", "--porcelain"], in: clone))
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if known.contains(standardized), FileManager.default.fileExists(atPath: path) {
            let dirty = !(try git(["status", "--porcelain"], in: path)).isEmpty
            if !dirty { try git(["checkout", "--quiet", "-B", branch, head], in: path) }
            let current = try git(["rev-parse", "HEAD"], in: path)
            return PRWorktree(path: path, branch: branch, remote: remote, headOid: current, reused: true, dirty: dirty)
        }
        if known.contains(standardized) { try? git(["worktree", "prune"], in: clone) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try git(["worktree", "add", "--quiet", "-B", branch, path, head], in: clone)
        return PRWorktree(path: path, branch: branch, remote: remote, headOid: head, reused: false, dirty: false)
    }

    static func existing(clone: String, number: Int) -> String? {
        let path = path(clone: clone, number: number)
        guard FileManager.default.fileExists(atPath: path),
              let list = try? git(["worktree", "list", "--porcelain"], in: clone),
              registered(list).contains(URL(fileURLWithPath: path).standardizedFileURL.path) else { return nil }
        return path
    }

    static func remove(clone: String, number: Int) throws {
        let path = path(clone: clone, number: number)
        guard (try git(["status", "--porcelain"], in: path)).isEmpty else {
            throw GitError(message: "The worktree has uncommitted changes. Commit or discard them first.")
        }
        try git(["worktree", "remove", path], in: clone)
        try? git(["branch", "-D", branch(number: number)], in: clone)
    }

    static func adapt(_ prompt: String, worktree: PRWorktree, pr: PullRequestDetail, repo: RepoRef) -> String {
        let fork = pr.headRepository.map { $0.nameWithOwner.lowercased() != repo.full.lowercased() } ?? false
        var note = "You are working in an isolated git worktree at \(worktree.path) on local branch \(worktree.branch), checked out at the pull request head \(worktree.headOid.prefix(12)). Do not run `gh pr checkout` and do not switch branches; my main checkout is not affected."
        if worktree.dirty { note += " The worktree already has uncommitted changes from an earlier session; keep them unless they conflict with this task." }
        var out = prompt
        let checkout = [
            FixPrompt.checkoutStep(pr.number),
            "Before starting: make sure the working tree is on the PR branch — run `gh pr checkout \(pr.number)` and `git pull`. If there are uncommitted local changes, stop and ask me first."
        ]
        if let hit = checkout.first(where: { out.contains($0) }) {
            out = out.replacingOccurrences(of: hit, with: hit.hasPrefix("Before starting") ? "Before starting: " + note : note)
        } else {
            out = note + "\n\n" + out
        }
        let push = fork
            ? "ask me before pushing: this pull request's branch lives in the fork \(pr.headRepository?.nameWithOwner ?? "")"
            : "`git push \(worktree.remote) HEAD:\(pr.headRefName)`"
        return out.replacingOccurrences(of: "(`git push`)", with: "(\(push))")
    }
}
