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
        case "preview":
            preview(message, client: client)
        case "edit":
            editMessage(message, client: client)
        case "history":
            sendHistory(message, client: client)
        case "resume":
            resume(message, client: client)
        case "subscribe":
            guard let session = message.session else { return }
            if client.subscriptions.insert(session).inserted || message.text == "reset" {
                client.sentItems[session] = nil
                client.sentOrder[session] = nil
                client.sentState[session] = nil
            }
            pushUpdates(to: client, only: session)
        case "unsubscribe":
            if let session = message.session { client.subscriptions.remove(session) }
        case "send":
            guard let tab = tab(message.session), let chat = tab.chat else { return }
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let attachments = message.attachments ?? []
            guard !text.isEmpty || !attachments.isEmpty else { return }
            var images: [ChatImage] = []
            var paths: [String] = []
            for attachment in attachments {
                if Self.inlineImageTypes.contains(attachment.mediaType), attachment.data.count <= ChatImage.maxBytes {
                    images.append(ChatImage(data: attachment.data, mediaType: attachment.mediaType))
                } else if let url = Self.store(attachment) {
                    paths.append(url.path)
                }
            }
            var prompt = text
            if !paths.isEmpty {
                prompt += (prompt.isEmpty ? "" : "\n\n") + "Files attached from the iPhone:\n" + paths.map { "- \($0)" }.joined(separator: "\n")
            }
            if !chat.running { tab.ensureChatRunning() }
            chat.send(prompt, images: images)
        case "permission":
            guard let chat = tab(message.session)?.chat, let request = chat.pendingPermissions.first(where: { $0.id == message.requestID }) else { return }
            chat.respond(request, allow: message.allow ?? false, always: message.always == true ? request.suggestions.first : nil)
        case "stop":
            tab(message.session)?.chat?.interrupt()
        case "close":
            if let tab = tab(message.session) { app?.claude.close(tab) }
            if let session = message.session {
                client.subscriptions.remove(session)
                client.sentItems[session] = nil
                client.sentOrder[session] = nil
                client.sentState[session] = nil
            }
            var reply = PYLinkMessage(type: "sessions")
            reply.id = message.id
            reply.sessions = sessions()
            client.channel.send(json: reply)
        default:
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = "Unsupported request: \(message.type)"
            client.channel.send(json: reply)
        }
    }

    private static let inlineImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    private static func store(_ attachment: PYLinkAttachment) -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("PullYard/iPhone Attachments", isDirectory: true).appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        var name = (attachment.name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name.hasPrefix(".") { name = "attachment" + name }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try attachment.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
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

    private func sendHistory(_ message: PYLinkMessage, client: PYLinkClient) {
        guard let app else { return }
        Task { @MainActor in
            await app.claude.reloadProjects(force: false)
            let open = Dictionary(app.claude.tabs.filter { $0.chat != nil && !$0.sessionId.isEmpty }.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
            let recent = app.claude.projects.flatMap(\.sessions).filter { !$0.archived }.sorted { $0.modified > $1.modified }.prefix(60)
            var reply = PYLinkMessage(type: "history")
            reply.id = message.id
            reply.sessions = recent.map { info in
                PYLinkSession(id: info.id, title: info.title, folder: info.cwd, state: open[info.id].map { Self.state($0.state) } ?? "closed", repo: info.prURL.flatMap(Self.repo(fromURL:)), number: info.prNumber, updated: info.modified)
            }
            client.channel.send(json: reply)
        }
    }

    private func resume(_ message: PYLinkMessage, client: PYLinkClient) {
        func fail(_ text: String) {
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = text
            client.channel.send(json: reply)
        }
        guard let app, let id = message.session else { return fail("Missing session.") }
        Task { @MainActor in
            if app.claude.sessionsByID[id] == nil { await app.claude.reloadProjects(force: true) }
            let tab: ClaudeTab
            if let open = app.claude.tabs.first(where: { $0.sessionId == id && $0.chat != nil }) {
                tab = open
            } else if let info = app.claude.sessionsByID[id] {
                guard FileManager.default.fileExists(atPath: info.cwd) else { return fail("The folder of this session no longer exists on \(server.desktopName).") }
                tab = app.claude.resume(info, kind: .chat)
            } else {
                return fail("This session isn't on \(server.desktopName) anymore.")
            }
            var reply = PYLinkMessage(type: "started")
            reply.id = message.id
            reply.session = tab.id.uuidString
            reply.sessions = sessions()
            client.channel.send(json: reply)
            client.subscriptions.insert(tab.id.uuidString)
            pushUpdates(to: client, only: tab.id.uuidString)
        }
    }

    private struct FixPlan {
        let pr: PullRequestDetail
        let repo: RepoRef
        let folder: String
        let prompt: String
        let name: String
        let kind: String
        let number: Int
    }

    private enum FixFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }

    private func plan(_ message: PYLinkMessage) async throws -> FixPlan {
        guard let app, let api = app.api else { throw FixFailure.message("PullYard on \(server.desktopName) isn't signed in to GitHub.") }
        guard let full = message.repo, let repo = RepoRef(full: full), let number = message.number else { throw FixFailure.message("Missing pull request.") }
        let kind = message.kind ?? "comments"
        let extra = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let response = try await api.pullRequest(ItemRef(repo: repo, number: number))
        guard let pr = response.repository?.pullRequest else { throw FixFailure.message("\(full) #\(number) isn't available to this account.") }
        guard let folder = await LocalRepoStore.detect(repo) else {
            throw FixFailure.message("There's no local clone of \(full) on \(server.desktopName). Open the pull request once in PullYard on the Mac and pick its folder.")
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
        if let edited = message.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !edited.isEmpty { prompt = edited }
        return FixPlan(pr: pr, repo: repo, folder: folder, prompt: prompt, name: name, kind: kind, number: number)
    }

    private func editMessage(_ message: PYLinkMessage, client: PYLinkClient) {
        func fail(_ text: String) {
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = text
            client.channel.send(json: reply)
        }
        guard let app, let tab = tab(message.session), let chat = tab.chat else { return fail("This session isn't open on \(server.desktopName).") }
        let replacement = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !replacement.isEmpty else { return fail("The message is empty.") }
        guard !chat.busy else { return fail("The agent is working. Stop it first, then edit the message.") }
        guard chat.sessionId?.isEmpty == false else { return fail("This session can't be edited yet.") }
        guard let itemID = message.replacesItem, itemID.hasPrefix("u") else { return fail("Only your own messages can be edited.") }
        let uid = String(itemID.dropFirst())
        guard let index = chat.items.firstIndex(where: { if case .user(let id, _, _) = $0 { return id == uid } else { return false } }),
              case let .user(_, original, images) = chat.items[index] else { return fail("That message isn't in this session anymore.") }
        let later = chat.items[(index + 1)...].filter { if case .user(_, let text, _) = $0 { return text == original } else { return false } }.count
        let touchedFiles = chat.items[(index + 1)...].contains {
            if case .tool(let call) = $0 { return ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(call.name) }
            return false
        }
        let before = Set(app.claude.tabs.map(\.id))
        let previousError = chat.lastError
        app.claude.rewind(tab, to: original, occurrenceFromEnd: later, replacement: replacement, images: images, filesChanged: touchedFiles)
        Task { @MainActor in
            for _ in 0..<75 {
                try? await Task.sleep(for: .milliseconds(200))
                if let next = app.claude.tabs.first(where: { !before.contains($0.id) && $0.chat != nil }) {
                    let old = tab.id.uuidString
                    client.subscriptions.remove(old)
                    client.sentItems[old] = nil
                    client.sentOrder[old] = nil
                    client.sentState[old] = nil
                    var reply = PYLinkMessage(type: "started")
                    reply.id = message.id
                    reply.session = next.id.uuidString
                    reply.sessions = sessions()
                    client.channel.send(json: reply)
                    client.subscriptions.insert(next.id.uuidString)
                    pushUpdates(to: client, only: next.id.uuidString)
                    return
                }
                if let error = chat.lastError, error != previousError { return fail(error) }
            }
            fail("Editing didn't finish on \(server.desktopName).")
        }
    }

    private func preview(_ message: PYLinkMessage, client: PYLinkClient) {
        Task { @MainActor in
            var reply = PYLinkMessage(type: "preview")
            reply.id = message.id
            do {
                let plan = try await plan(message)
                reply.prompt = plan.prompt
                reply.text = plan.name
            } catch {
                reply.type = "error"
                reply.error = error.localizedDescription
            }
            client.channel.send(json: reply)
        }
    }

    private func startFix(_ message: PYLinkMessage, client: PYLinkClient) {
        func fail(_ text: String) {
            var reply = PYLinkMessage(type: "error")
            reply.id = message.id
            reply.error = text
            client.channel.send(json: reply)
        }
        guard let app else { return }
        Task { @MainActor in
            do {
                let plan = try await plan(message)
                let isolate = UserDefaults.standard.object(forKey: "agentFix.isolatedWorktree") as? Bool ?? true
                let mode = ClaudePermissionMode(rawValue: UserDefaults.standard.string(forKey: "claudeMode") ?? "") ?? .standard
                guard let tab = try await ClaudeLauncher.startForPR(app: app, prompt: plan.prompt, folder: plan.folder, isolate: isolate, pr: plan.pr, repo: plan.repo, target: .app, mode: mode, name: plan.name) else {
                    return fail("The agent didn't start on \(server.desktopName).")
                }
                if plan.kind == "conflicts" || plan.kind == "comments" {
                    app.claude.prFixes[ItemRef(repo: plan.repo, number: plan.number)] = CIFixLaunch(tabID: tab.id, target: .app, headOid: plan.pr.headRefOid, at: Date())
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
            let previous = client.sentItems[session] ?? [:]
            let items = Self.items(chat.items.suffix(previous.isEmpty ? 40 : 200))
            let order = items.map(\.id)
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
            case let .user(id, text, images):
                return PYLinkItem(id: "u" + id, kind: "user", text: text, files: images.isEmpty ? nil : images.map { _ in "image" })
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
