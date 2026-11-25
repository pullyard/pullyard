import Foundation

@MainActor
struct PYLinkBridge {
    let server: PYLinkServer
    weak var app: AppModel?

    func handle(_ message: PYLinkMessage, client: PYLinkClient) {
        switch message.type {
        case "list":
            var reply = PYLinkMessage(type: "sessions")
            reply.id = message.id
            reply.sessions = sessions()
            client.channel.send(json: reply)
        case "fix":
            startFix(message, client: client)
        case "subscribe":
            guard let session = message.session else { return }
            client.subscriptions.insert(session)
            client.sentItems[session] = nil
            client.sentOrder[session] = nil
            client.sentState[session] = nil
            pushUpdates(to: client, only: session)
        case "unsubscribe":
            if let session = message.session { client.subscriptions.remove(session) }
        case "send":
            guard let chat = tab(message.session)?.chat, let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if !chat.running { tab(message.session)?.ensureChatRunning() }
            chat.send(text)
        case "permission":
            guard let chat = tab(message.session)?.chat, let request = chat.pendingPermissions.first(where: { $0.id == message.requestID }) else { return }
            chat.respond(request, allow: message.allow ?? false, always: message.always == true ? request.suggestions.first : nil)
        case "stop":
            tab(message.session)?.chat?.interrupt()
        default:
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = "Unsupported request: \(message.type)"
            client.channel.send(json: reply)
        }
    }

    private func tab(_ id: String?) -> ClaudeTab? {
        guard let id, let app else { return nil }
        return app.claude.tabs.first { $0.id.uuidString == id }
    }

    private func sessions() -> [PYLinkSession] {
        guard let app else { return [] }
        return app.claude.tabs.filter { $0.chat != nil }.map { tab in
            let pr = app.claude.pullRequest(for: tab)
            return PYLinkSession(id: tab.id.uuidString, title: tab.title, folder: tab.folder, state: Self.state(tab.state), repo: pr.flatMap { Self.repo(fromURL: $0.url) }, number: pr?.number)
        }
    }

    private static func state(_ state: ClaudeTabState) -> String {
        switch state {
        case .working: return "working"
        case .waiting: return "waiting"
        case .active: return "active"
        case .sleeping: return "sleeping"
        case .stopped: return "stopped"
        }
    }

    private static func repo(fromURL url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let parts = parsed.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    private func startFix(_ message: PYLinkMessage, client: PYLinkClient) {
        func fail(_ text: String) {
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = text
            client.channel.send(json: reply)
        }
        guard let app, let api = app.api else { return fail("PullYard on \(server.desktopName) isn't signed in to GitHub.") }
        guard let full = message.repo, let repo = RepoRef(full: full), let number = message.number else { return fail("Missing pull request.") }
        let kind = message.kind ?? "comments"
        let extra = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task { @MainActor in
            do {
                let response = try await api.pullRequest(ItemRef(repo: repo, number: number))
                guard let pr = response.repository?.pullRequest else { return fail("\(full) #\(number) isn't available to this account.") }
                guard let folder = await LocalRepoStore.detect(repo) else {
                    return fail("There's no local clone of \(full) on \(server.desktopName). Open the pull request once in PullYard on the Mac and pick its folder.")
                }
                var prompt: String
                let name: String
                switch kind {
                case "conflicts":
                    prompt = ConflictPrompt.build(pr: pr, repo: repo, files: [], push: true)
                    name = "Resolve conflicts PR #\(number): \(pr.title)"
                case "custom":
                    prompt = "Work on pull request #\(number) \"\(pr.title)\" in \(full).\nPR: \(pr.url)\nBranch: \(pr.headRefName) → \(pr.baseRefName)\n\n1. \(FixPrompt.checkoutStep(number))"
                    name = "PR #\(number): \(pr.title)"
                default:
                    let threads = pr.reviewThreads.nodes.filter { !$0.isResolved && !$0.isOutdated }
                    prompt = FixPrompt.build(pr: pr, repo: repo, threads: threads, general: FixPrompt.generalFeedback(pr), options: FixOptions(includeGeneral: true, commit: true, push: true, replyAndResolve: false))
                    name = "Fix PR #\(number): \(pr.title)"
                }
                if !extra.isEmpty { prompt += "\n\nAdditional instructions from the iPhone:\n\(extra)" }
                let isolate = UserDefaults.standard.object(forKey: "agentFix.isolatedWorktree") as? Bool ?? true
                let mode = ClaudePermissionMode(rawValue: UserDefaults.standard.string(forKey: "claudeMode") ?? "") ?? .standard
                guard let tab = try await ClaudeLauncher.startForPR(app: app, prompt: prompt, folder: folder, isolate: isolate, pr: pr, repo: repo, target: .app, mode: mode, name: name) else {
                    return fail("The agent didn't start on \(server.desktopName).")
                }
                if kind == "conflicts" || kind == "comments" {
                    app.claude.prFixes[ItemRef(repo: repo, number: number)] = CIFixLaunch(tabID: tab.id, target: .app, headOid: pr.headRefOid, at: Date())
                }
                var reply = PYLinkMessage(type: "started")
                reply.id = message.id
                reply.session = tab.id.uuidString
                reply.sessions = sessions()
                client.channel.send(json: reply)
                client.subscriptions.insert(tab.id.uuidString)
                pushUpdates(to: client, only: tab.id.uuidString)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func pushUpdates(to client: PYLinkClient, only: String? = nil) {
        for session in client.subscriptions where only == nil || session == only {
            guard let tab = tab(session), let chat = tab.chat else {
                var gone = PYLinkMessage(type: "update")
                gone.session = session
                gone.state = PYLinkSessionState(running: false, busy: false, status: nil, error: "This session was closed on the Mac.", pending: [])
                client.channel.send(json: gone)
                client.subscriptions.remove(session)
                continue
            }
            let items = Self.items(chat.items.suffix(200))
            let order = items.map(\.id)
            let previous = client.sentItems[session] ?? [:]
            let changed = items.filter { previous[$0.id] != $0 }
            let state = PYLinkSessionState(running: chat.running, busy: chat.busy, status: chat.status, error: chat.lastError, pending: chat.pendingPermissions.filter { !$0.resolved }.map(Self.permission))
            let orderChanged = client.sentOrder[session] != order
            let stateChanged = client.sentState[session] != state
            guard !changed.isEmpty || orderChanged || stateChanged else { continue }
            var update = PYLinkMessage(type: previous.isEmpty ? "snapshot" : "update")
            update.session = session
            update.items = changed
            if orderChanged { update.order = order }
            if stateChanged { update.state = state }
            update.text = tab.title
            client.channel.send(json: update)
            client.sentItems[session] = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            client.sentOrder[session] = order
            client.sentState[session] = state
        }
    }

    private static func items(_ source: ArraySlice<ChatItem>) -> [PYLinkItem] {
        source.map { item in
            switch item {
            case let .user(id, text, _):
                return PYLinkItem(id: "u" + id, kind: "user", text: text)
            case let .text(value):
                return PYLinkItem(id: "t" + value.id, kind: "text", text: value.text)
            case let .thinking(value):
                return PYLinkItem(id: "k" + value.id, kind: "thinking", text: String(value.text.prefix(600)))
            case let .tool(call):
                let status: String
                switch call.status {
                case .running: status = "running"
                case .done: status = "done"
                case .error: status = "error"
                case .denied: status = "denied"
                }
                let pending = call.permission.flatMap { $0.resolved ? nil : permission($0) }
                return PYLinkItem(id: "c" + call.id, kind: "tool", text: summary(call), tool: call.name, status: status, permission: pending)
            case let .notice(id, text, isError):
                return PYLinkItem(id: "n" + id, kind: isError ? "error" : "notice", text: text)
            }
        }
    }

    private static func summary(_ call: ChatToolCall) -> String {
        let keys = ["command", "file_path", "path", "pattern", "url", "description", "query", "prompt"]
        for key in keys { if let value = call.string(key), !value.isEmpty { return String(value.prefix(240)) } }
        if call.name == "TodoWrite", let todos = call.input["todos"] as? [[String: Any]] {
            return todos.compactMap { ($0["status"] as? String == "completed" ? "✓ " : "• ") + (($0["content"] as? String) ?? "") }.joined(separator: "\n")
        }
        return ""
    }

    private static func permission(_ request: PermissionRequest) -> PYLinkPermission {
        let detail = (request.input["command"] as? String) ?? (request.input["file_path"] as? String) ?? request.blockedPath
        return PYLinkPermission(id: request.id, tool: request.toolName, summary: request.description ?? "\(request.toolName) wants to run", detail: detail.map { String($0.prefix(400)) })
    }
}
