import Foundation

/// Asks Haiku to read the project and the ticket, then write the prompt the real agent starts with.
/// Read-only tools, no MCP, nothing saved, so it is cheap and can't change the checkout.
enum JiraPromptDrafter {
    static let instructions = """
    You prepare work for a coding agent. You get a Jira ticket and run inside the project's repository.
    Look around the code first, quickly: use Glob and Grep to find the screens, classes, routes and tests \
    the ticket is about, and Read only the few files that matter. Do not change anything.
    Then reply with ONLY the prompt for the coding agent, no preface. Write it in English, under 350 words, as plain text:
    - first line: what to do, with the ticket key;
    - Context: what the ticket says, short (keep steps to reproduce for bugs);
    - Where to look: the relevant files as repo-relative paths, one line each on why;
    - Likely cause or approach: your best guess, marked as a guess when unsure;
    - Done when: acceptance criteria and how to verify (tests to run or add).
    Keep the ticket URL. Do not invent files you did not see.
    """

    static func arguments() -> [String] {
        ["-p", "--model", "haiku", "--output-format", "json",
         "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob",
         "--max-turns", "14", "--strict-mcp-config", "--no-session-persistence",
         "--disable-slash-commands", "--append-system-prompt", instructions]
    }

    static func request(for issue: JiraIssue) -> String {
        "Prepare the prompt for this ticket.\n\n" + String(JiraImplementForm.defaultPrompt(issue).prefix(8000))
    }

    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class JiraPromptDraftRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
        let p = lock.withLock { process }
        if p?.isRunning == true { p?.terminate() }
    }

    @MainActor
    func run(issue: JiraIssue, folder: String, configDir: String?) async throws -> String {
        guard let bin = ClaudeLauncher.claudeBinary else { throw APIError(message: "Claude Code CLI not found") }
        let request = JiraPromptDrafter.request(for: issue)
        return try await Task.detached(priority: .userInitiated) { [self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = JiraPromptDrafter.arguments()
            p.currentDirectoryURL = URL(fileURLWithPath: folder)
            var env = ProcessInfo.processInfo.environment
            for key in env.keys where key == "PULLYARD_TOKEN" || key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
            ClaudeProfiles.apply(configDir, to: &env)
            env["PATH"] = [(bin as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            p.environment = env
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errors
            let stop = lock.withLock { () -> Bool in
                if !cancelled { process = p }
                return cancelled
            }
            if stop { throw CancellationError() }
            try p.run()
            input.fileHandleForWriting.write(Data(request.utf8))
            try? input.fileHandleForWriting.close()
            let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timer)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let err = errors.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            timer.cancel()
            if lock.withLock({ cancelled }) { throw CancellationError() }
            let text = String(decoding: data, as: UTF8.self)
            if p.terminationStatus != 0, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let message = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw APIError(message: message.isEmpty ? "Haiku stopped (status \(p.terminationStatus))" : String(message.prefix(300)))
            }
            let result = JiraPromptDrafter.clean(try ReviewDrafts.resultText(text))
            guard !result.isEmpty else { throw APIError(message: "Haiku returned an empty prompt") }
            return result
        }.value
    }
}
