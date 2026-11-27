import Foundation

/// Asks Haiku to read the project and the ticket, then write the prompt the real agent starts with.
/// Read-only tools, no MCP, nothing saved, so it is cheap and can't change the checkout.
enum JiraPromptDrafter {
    static let instructions = """
    You prepare work for a coding agent. You get a Jira ticket and run inside the project's repository. Do not change anything.

    1. Investigate. Use Glob and Grep to find the screens, classes, routes, API models and tests the ticket is about,     and Read only the files that matter. Use at most about 12 tool calls.
    2. Never guess. Every statement in the final prompt must be either verified in this repository (cite path:line)     or confirmed by the user's answers. When something decides the fix and you cannot verify it here, ask instead of guessing:     what the backend sends (field names, types, enum values, nullability), which screen or flow is meant, expected product     or design behaviour, environment, reproduction details, anything the ticket leaves ambiguous.
    3. Ask as many questions as the fix needs, and only those whose answer changes the fix. Make each one easy to answer:     concrete, with 2 to 4 likely options when you can (the user may also type a free answer). When the user has to ask     someone else (backend, design, product, QA), set "who" to that and phrase the question so it can be forwarded as is.

    Reply with ONLY one JSON object, no prose and no code fence. Either:
    {"status":"questions","findings":"what you verified, with repo-relative paths and line numbers, so the next step does not need to re-read the code","questions":[{"question":"...","why":"how the answer changes the fix","who":"you|backend|design|product|qa","options":["...","..."]}]}
    or, when everything needed is known:
    {"status":"ready","prompt":"..."}

    When answers are given, treat them as facts. An answer of "skipped" means unknown: do not guess it, list it under     "Verify first" in the prompt as something the agent must confirm before changing code. Ask follow-up questions only     if an answer opened a new unknown that decides the fix.

    The prompt is plain text in English, under 450 words:
    - first line: what to do, with the ticket key and URL;
    - Context: what the ticket says (keep steps to reproduce for bugs);
    - Facts: verified findings and the user's answers;
    - Where to look: files as repo-relative paths with lines, one line each on why;
    - Fix: the change to make, based only on the facts;
    - Verify first: open items, if any;
    - Done when: acceptance criteria and the tests to run or add.
    """

    static func arguments() -> [String] {
        ["-p", "--model", "haiku", "--output-format", "json",
         "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob",
         "--max-turns", "30", "--strict-mcp-config", "--no-session-persistence",
         "--disable-slash-commands", "--append-system-prompt", instructions]
    }

    static func request(for issue: JiraIssue, followUp: JiraDraftFollowUp? = nil) -> String {
        var text = "Prepare the prompt for this ticket.\n\n" + String(JiraImplementForm.defaultPrompt(issue).prefix(8000))
        if let followUp {
            text += "\n\nWhat you verified earlier:\n" + followUp.findings
            text += "\n\nThe user's answers:\n" + followUp.answers.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")
        }
        return text
    }

    /// Haiku's reply: questions to ask, or the finished prompt. A reply that isn't the expected JSON is taken as the prompt.
    static func outcome(_ raw: String) -> JiraDraftOutcome {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.firstIndex(of: "{"), let close = t.lastIndex(of: "}"), open < close,
           let obj = (try? JSONSerialization.jsonObject(with: Data(t[open...close].utf8))) as? [String: Any] {
            let questions = (obj["questions"] as? [[String: Any]] ?? []).compactMap { q -> JiraDraftQuestion? in
                guard let text = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return JiraDraftQuestion(question: text, why: q["why"] as? String, who: q["who"] as? String,
                                         options: (q["options"] as? [String] ?? []).filter { !$0.isEmpty })
            }
            if obj["status"] as? String == "questions", !questions.isEmpty {
                return .questions(findings: obj["findings"] as? String ?? "", questions)
            }
            if let prompt = (obj["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                return .ready(prompt)
            }
        }
        return .ready(clean(t))
    }

    /// The prompt itself: the fenced block when Haiku wrapped it in one, else the whole reply.
    static func clean(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = t.range(of: "```") {
            let afterOpen = t[open.upperBound...]
            let body = afterOpen.drop { $0 != "\n" }.dropFirst()
            if let close = body.range(of: "```", options: .backwards) {
                let inner = String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.count > 80 { return inner }
            }
        }
        return t
    }
}

struct JiraDraftQuestion: Identifiable, Equatable, Sendable {
    let id = UUID()
    let question: String
    let why: String?
    let who: String?
    let options: [String]

    static func == (a: Self, b: Self) -> Bool { a.question == b.question && a.options == b.options && a.who == b.who }

    /// Who has the answer, when it isn't the user.
    var askLabel: String? {
        guard let who = who?.lowercased(), !who.isEmpty, who != "you", who != "user" else { return nil }
        return "Ask " + who
    }
}

struct JiraDraftFollowUp: Sendable {
    let findings: String
    let answers: [(question: String, answer: String)]
}

enum JiraDraftOutcome: Sendable {
    case ready(String)
    case questions(findings: String, [JiraDraftQuestion])
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
    func run(issue: JiraIssue, folder: String, configDir: String?, followUp: JiraDraftFollowUp? = nil) async throws -> JiraDraftOutcome {
        guard let bin = ClaudeLauncher.claudeBinary else { throw APIError(message: "Claude Code CLI not found") }
        let request = JiraPromptDrafter.request(for: issue, followUp: followUp)
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
            let result = try ReviewDrafts.resultText(text)
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError(message: "Haiku returned an empty prompt") }
            return JiraPromptDrafter.outcome(result)
        }.value
    }
}
