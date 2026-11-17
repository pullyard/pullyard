import AppKit
import SwiftUI

struct FixTourStep: Identifiable {
    let id: Int
    let title: String
    let before: String
    let after: String
    let tryIt: String
    var actionTitle: String?
}

@Observable
@MainActor
final class FixTour {
    static let shared = FixTour()

    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return Demo.fixTour || UserDefaults.standard.bool(forKey: "debug.fixTour")
        #endif
    }

    var active = false
    var index = 0
    var note: String?
    @ObservationIgnored var autoStarted = false
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private weak var tab: ClaudeTab?
    @ObservationIgnored private var ledger = AgentUsageLedger(file: nil)
    @ObservationIgnored private var lastRequest = ""
    @ObservationIgnored private var delivers = true
    @ObservationIgnored private var folder = ""

    let steps: [FixTourStep] = [
        FixTourStep(id: 0, title: "Agent defaults in Settings", before: "Model, effort and permission mode had to be picked again in every chat.", after: "Settings → Agents sets them once for every new chat and terminal session.", tryIt: "Open Agent Settings, pick Auto as the permission mode, then start a new chat.", actionTitle: "Open Agent Settings"),
        FixTourStep(id: 1, title: "Drafts survive tab switches", before: "Typed text and attached images vanished when you switched tabs.", after: "The draft and its attachments stay with the session.", tryIt: "The composer holds a draft with an image. Switch to another section and come back."),
        FixTourStep(id: 2, title: "Queued messages", before: "A message sent while the agent worked went straight to the CLI and could not be taken back.", after: "It waits in the app, is marked Queued and has a Cancel link.", tryIt: "The second message is queued. Cancel it, or finish the turn to see it delivered.", actionTitle: "Finish the turn"),
        FixTourStep(id: 3, title: "Rejected model change rolls back", before: "If the CLI refused a model, mode or effort change the picker still showed the new value.", after: "The picker returns to the real value and an error appears in the chat.", tryIt: "The demo asked for Opus and the CLI refused. The model menu still says Sonnet."),
        FixTourStep(id: 4, title: "Undelivered message is reported", before: "If the process was gone the message was silently lost and the chat looked busy.", after: "An error says the message was not delivered.", tryIt: "The demo sent a message to a dead process. See the red notice."),
        FixTourStep(id: 5, title: "Session cost is not double counted", before: "Each turn's cumulative total was added again, so two turns of $0.0085 and $0.0141 showed $0.0226.", after: "The session shows the cumulative total.", tryIt: "Open the usage ring in the composer."),
        FixTourStep(id: 6, title: "No false \"Sign-in expired\"", before: "Any error mentioning 401 or an API key showed the sign-in banner.", after: "Only real authentication errors do.", tryIt: "A tool error mentioning 401 is shown as a normal notice."),
        FixTourStep(id: 7, title: "Search in conversation", before: "There was no way to find text in a long chat.", after: "⌘F opens search with previous and next match.", tryIt: "Click the chat, press ⌘F and type \"retry\"."),
        FixTourStep(id: 8, title: "Prompt history", before: "Earlier prompts had to be retyped.", after: "↑ and ↓ in an empty composer walk through sent prompts.", tryIt: "Click the empty composer and press ↑."),
        FixTourStep(id: 9, title: "Multi-select questions", before: "Questions that allow several answers only accepted one.", after: "Several options can be ticked and are sent together.", tryIt: "Tick two options in the question card."),
        FixTourStep(id: 10, title: "MCP server status", before: "A failed or signed-out MCP server was invisible.", after: "The composer shows how many servers are down.", tryIt: "Open the amber MCP menu in the composer bar."),
        FixTourStep(id: 11, title: "History keeps thinking and images", before: "Resumed sessions dropped thinking blocks and attached images.", after: "Both are restored, and parsing no longer blocks the window.", tryIt: "The first message has its image and the reply starts with a thinking block."),
        FixTourStep(id: 12, title: "Drop images anywhere", before: "Only a thin strip accepted drops and the highlight flickered.", after: "The whole chat pane is a drop target with a steady highlight.", tryIt: "Drag an image from Finder over the chat, or preview the highlight.", actionTitle: "Preview highlight"),
        FixTourStep(id: 13, title: "Export and copy as Markdown", before: "A conversation could not be taken out of the app.", after: "The tab's … menu copies or exports it as Markdown.", tryIt: "Use the … menu, or copy the demo transcript now.", actionTitle: "Copy transcript"),
        FixTourStep(id: 14, title: "Saved prompts", before: "Reusable prompts lived in notes outside the app.", after: "The bookmark menu in the composer saves and inserts prompts.", tryIt: "Type something, open the bookmark menu and save it."),
        FixTourStep(id: 15, title: "Refresh errors are visible", before: "A failed background refresh was swallowed and stale data looked current.", after: "After two failures a banner offers Retry.", tryIt: "The banner at the bottom is simulated. It clears on the next successful refresh."),
        FixTourStep(id: 16, title: "PR panel for GitLab, Bitbucket, Gitea", before: "The inspector said the folder was not linked to GitHub and offered a github.com link.", after: "It reads any remote and builds the right create link and agent prompt.", tryIt: "The demo folder has a gitlab.com remote. Open the PR tab in the inspector."),
        FixTourStep(id: 17, title: "Keyboard in the session list", before: "Sessions could only be opened with the mouse.", after: "↑ and ↓ move through open tabs and sessions, ↩ opens.", tryIt: "Click a row in the Agents list, then use the arrow keys."),
        FixTourStep(id: 18, title: "Usage by day", before: "Cost was only visible per session.", after: "Settings → Agents → Usage totals today, 7 and 30 days.", tryIt: "This demo recorded turns in a separate ledger so your real numbers are untouched.", actionTitle: "Open Agent Settings"),
        FixTourStep(id: 19, title: "Long sessions are trimmed", before: "Every item of a very long session stayed in memory.", after: "The oldest items are dropped from the view; the transcript on disk is complete.", tryIt: "The demo trimmed the list. See \"Showing the latest messages\" at the top."),
        FixTourStep(id: 20, title: "Quit warning and tab restore", before: "⌘Q killed working agents without asking and tabs were gone on relaunch.", after: "Quitting warns while agents work, and tabs reopen asleep.", tryIt: "The demo agent is working. Press ⌘Q and choose Cancel."),
        FixTourStep(id: 21, title: "Retry, edit and fork", before: "Editing a message dropped its images and gave no hint that files stayed changed.", after: "Images are kept, a notice explains file changes, and a message can be forked into a new tab.", tryIt: "These need a real session file. Hover one of your own messages in a real chat.")
    ]

    var step: FixTourStep { steps[min(index, steps.count - 1)] }

    var detail: String? {
        switch index {
        case 5: return tab?.chat.map { String(format: "Session total: $%.4f", $0.totalCost) }
        case 18:
            let today = ledger.total(lastDays: 1)
            return String(format: "Demo ledger today: $%.4f · %d turns", today.cost, today.turns)
        default: return nil
        }
    }

    func start(app: AppModel) {
        self.app = app
        note = nil
        index = 0
        active = true
        app.section = .claude
        Task { @MainActor in
            folder = await Task.detached(priority: .userInitiated) { FixTour.makeRepository() }.value
            show()
        }
    }

    func next() { move(to: index + 1) }
    func previous() { move(to: index - 1) }

    func move(to target: Int) {
        guard steps.indices.contains(target) else { return }
        index = target
        show()
    }

    func finish() {
        active = false
        note = nil
        app?.syncError = nil
        if let tab { app?.claude.close(tab) }
        tab = nil
    }

    func runAction() {
        guard let chat = tab?.chat else { return }
        switch index {
        case 0, 18:
            UserDefaults.standard.set("agents", forKey: "settings.tab")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case 2:
            chat.handle(["type": "result", "total_cost_usd": 0.0085])
            note = chat.queuedIDs.isEmpty ? "Turn finished — the queued message was sent." : nil
        case 12:
            chat.setDropHover(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak chat] in chat?.setDropHover(false, immediately: true) }
        case 13:
            copyToPasteboard(chat.markdownTranscript(title: tab?.title ?? "Demo"))
            note = "Copied to the clipboard."
        default:
            break
        }
    }

    private func show() {
        guard let app, !folder.isEmpty else { return }
        note = nil
        app.syncError = nil
        if let tab { app.claude.close(tab) }
        let tab = app.claude.openDemoTab(folder: folder, title: "Fixes demo")
        self.tab = tab
        guard let chat = tab.chat else { return }
        delivers = true
        ledger = AgentUsageLedger(file: nil)
        chat.ledger = ledger
        chat.running = true
        chat.transport = { [weak self] object in
            if let id = object["request_id"] as? String { self?.lastRequest = id }
            return self?.delivers ?? true
        }
        chat.onTurnFinished = nil
        chat.onNeedsInput = nil
        chat.model = "claude-sonnet-5-5"
        chat.modelValue = "sonnet"
        chat.models = [
            ChatModelOption(value: "default", displayName: "Default", description: "Recommended", efforts: []),
            ChatModelOption(value: "sonnet", displayName: "Sonnet", description: "Fast everyday model", efforts: ["low", "medium", "high"]),
            ChatModelOption(value: "opus", displayName: "Opus", description: "Most capable", efforts: ["low", "medium", "high", "max"])
        ]
        chat.mcpServers = [MCPServerStatus(name: "github", status: "connected")]
        chat.items = Self.conversation()
        app.section = .claude
        apply(index, chat: chat, app: app)
    }

    private func apply(_ index: Int, chat: ChatSession, app: AppModel) {
        switch index {
        case 1:
            chat.draftText = "Add a retry with backoff to the checkout client and cover it with tests"
            chat.draftImages = [Self.picture()]
        case 2:
            chat.send("Run the checkout tests")
            chat.send("Also update the changelog")
        case 3:
            chat.setModel("opus")
            chat.handle(["type": "control_response", "response": ["subtype": "error", "request_id": lastRequest, "error": "Opus is not available on this plan"]])
        case 4:
            delivers = false
            chat.send("Are you still there?")
        case 5:
            chat.send("Run the checkout tests")
            chat.handle(["type": "result", "total_cost_usd": 0.0085])
            chat.send("Now fix the flaky one")
            chat.handle(["type": "result", "total_cost_usd": 0.0141])
        case 6:
            chat.send("Fetch the open incidents")
            chat.handle(["type": "result", "is_error": true, "subtype": "error", "result": "MCP server returned 401 for tool fetch_incidents"])
        case 8:
            chat.send("Run the checkout tests")
            chat.handle(["type": "result", "total_cost_usd": 0.004])
            chat.send("Now fix the flaky one")
            chat.handle(["type": "result", "total_cost_usd": 0.009])
        case 9:
            chat.send("Set up the release")
            chat.handle(["type": "control_request", "request_id": "tour-question", "request": [
                "subtype": "can_use_tool",
                "tool_name": "AskUserQuestion",
                "input": ["questions": [[
                    "question": "Which platforms should this release cover?",
                    "header": "Platforms",
                    "multiSelect": true,
                    "options": [
                        ["label": "macOS", "description": "Universal build, notarized"],
                        ["label": "Windows", "description": "MSIX package"],
                        ["label": "Linux", "description": "Flatpak and AppImage"]
                    ]
                ]]]
            ]])
        case 10:
            chat.mcpServers = [
                MCPServerStatus(name: "github", status: "connected"),
                MCPServerStatus(name: "linear", status: "needs-auth"),
                MCPServerStatus(name: "sentry", status: "failed")
            ]
        case 15:
            app.syncError = "The Internet connection appears to be offline."
        case 16:
            app.claude.showInspector = true
            UserDefaults.standard.set(InspectorTab.pr.rawValue, forKey: "agents.inspectorTab")
        case 18:
            chat.send("Run the checkout tests")
            chat.handle(["type": "result", "total_cost_usd": 0.0085])
            chat.send("Now fix the flaky one")
            chat.handle(["type": "result", "total_cost_usd": 0.0141])
        case 19:
            chat.items += (1...30).map { ChatItem.notice(id: "filler\($0)", text: "Earlier step \($0)", isError: false) }
            chat.trimItems(limit: 12)
        case 20:
            chat.send("Refactor the checkout client")
            chat.status = "Working"
        default:
            break
        }
    }

    private static func conversation() -> [ChatItem] {
        func text(_ id: String, _ body: String) -> ChatText {
            let t = ChatText(id: id, text: body)
            t.finalized = true
            return t
        }
        let read = ChatToolCall(id: "tour-read", name: "Read")
        read.input = ["file_path": "Sources/Checkout/CheckoutClient.swift"]
        read.status = .done
        read.resultText = "final class CheckoutClient {\n    func submit(_ order: Order) async throws -> Receipt\n}"
        let edit = ChatToolCall(id: "tour-edit", name: "Edit")
        edit.input = [
            "file_path": "Sources/Checkout/CheckoutClient.swift",
            "old_string": "return try await send(order)",
            "new_string": "return try await retry(times: 3) { try await send(order) }"
        ]
        edit.status = .done
        edit.resultText = "The file has been updated."
        return [
            .user(id: "tour-u1", text: "Checkout fails on flaky networks, see the screenshot. Add a retry.", images: [picture()]),
            .thinking(text("tour-k1", "The failure is a single dropped request. A bounded retry with backoff around the network call is enough; payment must stay idempotent, so the retry has to reuse the same idempotency key.")),
            .text(text("tour-t1", "I'll wrap the submit call in a **retry with backoff** and keep the idempotency key stable so a retried request can't charge twice.")),
            .tool(read),
            .tool(edit),
            .text(text("tour-t2", "Done. `CheckoutClient.submit` now retries up to three times with exponential backoff. The retry reuses the original idempotency key.\n\n- 1st retry after 200 ms\n- 2nd retry after 400 ms\n- 3rd retry after 800 ms"))
        ]
    }

    private static func picture() -> ChatImage {
        let size = NSSize(width: 320, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(starting: NSColor.systemIndigo, ending: NSColor.systemTeal)?.draw(in: rect, angle: 35)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("Checkout failed\nNetwork connection lost" as NSString).draw(
                in: rect.insetBy(dx: 16, dy: 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: style]
            )
            return true
        }
        let data = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        return ChatImage(data: data, mediaType: "image/png")
    }

    nonisolated private static func makeRepository() -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PullYardFixesDemo", isDirectory: true)
        let dir = root.appendingPathComponent("storefront", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let sources = dir.appendingPathComponent("Sources/Checkout", isDirectory: true)
        try? fm.createDirectory(at: sources, withIntermediateDirectories: true)
        let client = sources.appendingPathComponent("CheckoutClient.swift")
        try? "final class CheckoutClient {\n    func submit(_ order: Order) async throws -> Receipt {\n        return try await send(order)\n    }\n}\n".write(to: client, atomically: true, encoding: .utf8)
        try? "# Storefront\n\nDemo repository for the PullYard fixes tour.\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let path = dir.path
        let identity = ["-c", "user.name=Alex Rivera", "-c", "user.email=alex@example.com", "-c", "commit.gpgsign=false"]
        _ = Git.run(["init", "-q", "-b", "main"], in: path)
        _ = Git.run(["add", "."], in: path)
        _ = Git.run(identity + ["commit", "-q", "-m", "Initial storefront"], in: path)
        _ = Git.run(["remote", "add", "origin", "git@gitlab.com:acme/storefront.git"], in: path)
        _ = Git.run(["checkout", "-q", "-b", "feat/checkout-retry"], in: path)
        try? "final class CheckoutClient {\n    func submit(_ order: Order) async throws -> Receipt {\n        return try await retry(times: 3) { try await send(order) }\n    }\n}\n".write(to: client, atomically: true, encoding: .utf8)
        return path
    }
}

struct FixTourOverlay: View {
    @Environment(AppModel.self) private var app
    private var tour: FixTour { FixTour.shared }

    var body: some View {
        if !tour.active, FixTour.isAvailable {
            Button { tour.start(app: app) } label: {
                Label("Fixes demo", systemImage: "checkmark.seal.fill")
                    .font(.syCallout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white)
            .background(Color.syAgentAccent, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .padding(16)
            .help("Walk through the recent chat fixes with mock data")
            .task {
                guard Demo.fixTour, !tour.autoStarted else { return }
                tour.autoStarted = true
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                tour.start(app: app)
            }
        }
        if tour.active {
            let step = tour.step
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.syAgentAccent)
                    Text("Fixes demo").font(.sySubheadline.weight(.semibold)).foregroundStyle(Color.syText)
                    Spacer()
                    Text("\(tour.index + 1) of \(tour.steps.count)").font(.syCaption).monospacedDigit().foregroundStyle(Color.syMuted)
                    Button { tour.finish() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Close the demo")
                        .accessibilityLabel("Close the demo")
                }
                Text(step.title).font(.syHeadline).foregroundStyle(Color.syText)
                row("Before", step.before, color: .syRed)
                row("Now", step.after, color: .syGreen)
                row("Try", step.tryIt, color: .sySky)
                if let detail = tour.detail {
                    Text(detail).font(.syCaption).monospacedDigit().foregroundStyle(Color.syText)
                }
                if let note = tour.note {
                    Text(note).font(.syCaption).foregroundStyle(Color.syGreen)
                }
                HStack(spacing: 8) {
                    Button("Back") { tour.previous() }.disabled(tour.index == 0)
                    if let action = step.actionTitle {
                        Button(action) { tour.runAction() }
                    }
                    Spacer()
                    if tour.index == tour.steps.count - 1 {
                        Button("Done") { tour.finish() }.buttonStyle(.borderedProminent).tint(.syAgentAccent)
                    } else {
                        Button("Next") { tour.next() }.buttonStyle(.borderedProminent).tint(.syAgentAccent).keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            .padding(16)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func row(_ label: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.syCaption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(text)
                .font(.syCallout)
                .foregroundStyle(Color.syMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
