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
        case "options":
            sendOptions(message, client: client)
        case "new":
            startNew(message, client: client)
        case "pin":
            setPinned(message, client: client)
        case "rename":
            rename(message, client: client)
        case "preview":
            preview(message, client: client)
        case "edit":
            editMessage(message, client: client)
        case "diff":
            var reply = PYLinkMessage(type: "diff")
            reply.id = message.id
            if let chat = tab(message.session)?.chat, let itemID = message.replacesItem, itemID.hasPrefix("c") {
                let callID = String(itemID.dropFirst())
                for case let .tool(call) in chat.items where call.id == callID {
                    reply.diff = Self.diff(call)
                    break
                }
            }
            if reply.diff == nil { reply.error = "This step has no file changes to show." }
            client.channel.send(json: reply)
        case "transcribe":
            transcribe(message, client: client)
        case "jira":
            var reply = PYLinkMessage(type: "jira")
            reply.id = message.id
            let store = JiraConnections.shared
            reply.jira = PYLinkJira(
                connections: store.linkConnections.compactMap { link in
                    guard let token = store.token(for: link.id) else { return nil }
                    let keys = store.connection(link.id)?.projectKeys ?? []
                    return PYLinkJiraConnection(id: link.id, name: link.name, site: link.site, email: link.email, token: token, projectKeys: keys)
                },
                orgOverrides: store.orgOverrides,
                repoOverrides: store.repoOverrides
            )
            client.channel.send(json: reply)
        case "history":
            sendHistory(message, client: client)
        case "resume":
            resume(message, client: client)
        case "subscribe":
            guard let session = message.session else { return }
            tab(session)?.loadPendingHistory()
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
            tab.loadPendingHistory()
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
            if let requestID = message.requestID, let request = chat.pendingPermissions.first(where: { $0.id == requestID && !$0.resolved }), !text.isEmpty {
                chat.respond(request, allow: false, message: text)
                return
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
        let root = support.appendingPathComponent("PullYard/iPhone Attachments", isDirectory: true)
        pruneAttachments(root)
        let folder = root.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        var name = String((attachment.name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "-").components(separatedBy: .newlines).joined(separator: " ").prefix(120))
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

    private static func pruneAttachments(_ root: URL) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff { try? fm.removeItem(at: folder) }
        }
    }

    private func transcribe(_ message: PYLinkMessage, client: PYLinkClient) {
        var reply = PYLinkMessage(type: "transcription")
        reply.id = message.id
        guard let audio = message.audio, !audio.data.isEmpty, audio.data.count <= 20 * 1024 * 1024 else {
            reply.error = "The recording is empty or too long."
            client.channel.send(json: reply)
            return
        }
        let ext = audio.mediaType.contains("wav") ? "wav" : (audio.mediaType.contains("caf") ? "caf" : "m4a")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pullyard-dictation-\(UUID().uuidString).\(ext)")
        let language = message.language.flatMap(DictationLanguage.init(rawValue:))
        Task { @MainActor in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try audio.data.write(to: file, options: .atomic)
                reply.text = try await WhisperEngine.shared.transcribe(file: file, language: language)
            } catch {
                reply.error = error.localizedDescription
            }
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
            let pending = tab.chat?.pendingPermissions.first { !$0.resolved }.map(Self.permission)
            return PYLinkSession(id: tab.id.uuidString, title: tab.title, folder: tab.folder, state: Self.state(tab.state), repo: pr.flatMap { Self.repo(fromURL: $0.url) }, number: pr?.number, sessionID: tab.sessionId, account: tab.profile?.id ?? ClaudeProfiles.defaultID, environment: tab.environmentID, pending: pending)
        }
    }

    static func prefs() -> PYLinkPrefs {
        let prefs = AgentSessionPrefs.shared
        return PYLinkPrefs(pinned: prefs.pinned, titles: prefs.titles)
    }

    private func reply(_ message: PYLinkMessage, error: String, client: PYLinkClient) {
        var reply = PYLinkMessage(type: "error")
        reply.id = message.id
        reply.error = error
        client.channel.send(json: reply)
    }

    private func sendOptions(_ message: PYLinkMessage, client: PYLinkClient) {
        guard let app else { return }
        let profiles = ClaudeProfiles.shared
        var reply = PYLinkMessage(type: "options")
        reply.id = message.id
        let recent = app.claude.projects.filter(\.exists).sorted { $0.lastActivity > $1.lastActivity }.prefix(80)
        reply.options = PYLinkOptions(
            accounts: profiles.visible.map { PYLinkAccount(id: $0.id, label: $0.label, email: $0.email, plan: $0.plan) },
            active: profiles.visible.contains { $0.id == profiles.activeID } ? profiles.activeID : profiles.visible.first?.id,
            environments: AgentEnvironments.shared.items.map { PYLinkEnvironment(id: $0.id, name: $0.name, icon: $0.icon, folders: $0.folders, variables: $0.variableNames) },
            projects: recent.map { PYLinkProject(path: $0.path, name: $0.name) }
        )
        reply.prefs = Self.prefs()
        client.sentPrefs = reply.prefs
        client.channel.send(json: reply)
    }

    private func launchChoice(_ message: PYLinkMessage) throws -> (profile: String?, environment: AgentEnvironment?) {
        var profile: String?
        if let id = message.account {
            guard ClaudeProfiles.shared.visible.contains(where: { $0.id == id }) else { throw FixFailure.message("That Claude account isn't on \(server.desktopName) anymore.") }
            profile = id
        }
        var environment: AgentEnvironment?
        if let id = message.environment {
            guard let found = AgentEnvironments.shared.environment(id: id) else { throw FixFailure.message("That environment isn't on \(server.desktopName) anymore.") }
            environment = found
        }
        return (profile, environment)
    }

    private func startNew(_ message: PYLinkMessage, client: PYLinkClient) {
        guard let app else { return }
        do {
            let choice = try launchChoice(message)
            let requested = message.folder?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let folder = (requested?.isEmpty == false ? requested : nil) ?? choice.environment?.startFolder else {
                return reply(message, error: "Pick a project folder for the new session.", client: client)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                return reply(message, error: "\((folder as NSString).lastPathComponent) doesn't exist on \(server.desktopName).", client: client)
            }
            let prompt = message.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tab = app.claude.newSession(folder: folder, prompt: prompt?.isEmpty == false ? prompt : nil, kind: .chat, profileID: choice.profile, environmentID: choice.environment?.id)
            var started = PYLinkMessage(type: "started")
            started.id = message.id
            started.session = tab.id.uuidString
            started.sessions = sessions()
            client.channel.send(json: started)
            client.subscriptions.insert(tab.id.uuidString)
            pushUpdates(to: client, only: tab.id.uuidString)
        } catch {
            reply(message, error: error.localizedDescription, client: client)
        }
    }

    private func sessionKey(_ id: String?) -> (key: String, tab: ClaudeTab?)? {
        guard let id, !id.isEmpty else { return nil }
        if let tab = tab(id) { return (tab.sessionId, tab) }
        return (id, app?.claude.tab(forSession: id))
    }

    private func sendPrefs(_ message: PYLinkMessage, client: PYLinkClient) {
        var reply = PYLinkMessage(type: "prefs")
        reply.id = message.id
        reply.prefs = Self.prefs()
        reply.sessions = sessions()
        client.sentPrefs = reply.prefs
        client.channel.send(json: reply)
    }

    private func setPinned(_ message: PYLinkMessage, client: PYLinkClient) {
        guard let found = sessionKey(message.session), !found.key.isEmpty else {
            return reply(message, error: "This session can't be pinned until the agent has started.", client: client)
        }
        AgentSessionPrefs.shared.setPinned(found.key, message.pinned ?? true)
        sendPrefs(message, client: client)
    }

    private func rename(_ message: PYLinkMessage, client: PYLinkClient) {
        guard let app, let found = sessionKey(message.session) else { return reply(message, error: "Missing session.", client: client) }
        let title = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let tab = found.tab, !title.isEmpty {
            app.claude.rename(tab, to: title)
        } else if !found.key.isEmpty {
            AgentSessionPrefs.shared.rename(found.key, to: title)
        } else {
            return reply(message, error: "This session can't be renamed yet.", client: client)
        }
        sendPrefs(message, client: client)
    }

    func pushPrefs(to client: PYLinkClient) {
        let current = Self.prefs()
        guard client.sentPrefs != current else { return }
        client.sentPrefs = current
        var message = PYLinkMessage(type: "prefs")
        message.prefs = current
        client.channel.send(json: message)
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
            let prefs = AgentSessionPrefs.shared
            let recent = app.claude.projects.flatMap(\.sessions).filter { !prefs.isArchived($0) }.sorted { a, b in
                let pa = prefs.isPinned(a.id), pb = prefs.isPinned(b.id)
                return pa != pb ? pa : a.modified > b.modified
            }.prefix(60)
            var reply = PYLinkMessage(type: "history")
            reply.id = message.id
            reply.sessions = recent.map { info in
                PYLinkSession(id: info.id, title: prefs.title(info), folder: info.cwd, state: open[info.id].map { Self.state($0.state) } ?? "closed", repo: info.prURL.flatMap(Self.repo(fromURL:)), number: info.prNumber, updated: info.modified, sessionID: info.id, account: info.profileID ?? ClaudeProfiles.defaultID)
            }
            reply.prefs = Self.prefs()
            client.sentPrefs = reply.prefs
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
                open.loadPendingHistory()
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
                let choice = try launchChoice(message)
                let isolate = UserDefaults.standard.object(forKey: "agentFix.isolatedWorktree") as? Bool ?? true
                let mode = ClaudePermissionMode(rawValue: UserDefaults.standard.string(forKey: "claudeMode") ?? "") ?? .standard
                guard let tab = try await ClaudeLauncher.startForPR(app: app, prompt: plan.prompt, folder: plan.folder, isolate: isolate, pr: plan.pr, repo: plan.repo, target: .app, mode: mode, name: plan.name, profileID: choice.profile, environmentID: choice.environment?.id) else {
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

    func pushSessions(to client: PYLinkClient) {
        let current = sessions()
        guard client.sentSessions != current else { return }
        let first = client.sentSessions == nil
        client.sentSessions = current
        guard !first else { return }
        var message = PYLinkMessage(type: "sessions")
        message.sessions = current
        client.channel.send(json: message)
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
            if chat.items.isEmpty && (chat.historyLoading || tab.pendingHistory != nil) { continue }
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

    private static func diff(_ call: ChatToolCall) -> PYLinkDiff? {
        let limit = 400_000
        func clip(_ text: String) -> String { text.count > limit ? String(text.prefix(limit)) : text }
        let path = call.string("file_path") ?? call.string("notebook_path") ?? ""
        switch call.name {
        case "Edit":
            return PYLinkDiff(path: path, tool: call.name, edits: [PYLinkEdit(old: clip(call.string("old_string") ?? ""), new: clip(call.string("new_string") ?? ""))])
        case "MultiEdit":
            let edits = (call.input["edits"] as? [[String: Any]] ?? []).map { PYLinkEdit(old: clip($0["old_string"] as? String ?? ""), new: clip($0["new_string"] as? String ?? "")) }
            return edits.isEmpty ? nil : PYLinkDiff(path: path, tool: call.name, edits: edits)
        case "Write":
            return PYLinkDiff(path: path, tool: call.name, edits: [PYLinkEdit(old: "", new: clip(call.string("content") ?? ""))])
        case "NotebookEdit":
            return PYLinkDiff(path: path, tool: call.name, edits: [PYLinkEdit(old: "", new: clip(call.string("new_source") ?? ""))])
        default:
            return nil
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
