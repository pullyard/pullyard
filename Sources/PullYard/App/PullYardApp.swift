import StackNotesKit
import SwiftUI

@main
enum Main {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains(StackNotesMCP.flag) {
            StackNotesMCPServer.run(arguments: CommandLine.arguments)
        } else if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else {
            LegacyMigration.run()
            DispatchQueue.global(qos: .utility).async { Updater.clearQuarantine() }
            UserDefaults.standard.register(defaults: ["pollInterval": 30.0])
            PullYardApp.main()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var workspace: ClaudeWorkspace?
    static var flushDrafts: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.flushDrafts?()
        guard let ws = Self.workspace else { return .terminateNow }
        ws.saveOpenTabs()
        let busy = ws.busyTabCount
        guard busy > 0, AgentDefaults.shared.confirmQuit else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy == 1 ? "An agent is still working" : "\(busy) agents are still working"
        alert.informativeText = "Quitting stops them mid-task. Their conversations are saved and reopen next time, but unfinished work is interrupted."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct PullYardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("PullYard", id: "main") {
            ThemedRoot {
                RootView()
                    .environment(app)
                    .frame(minWidth: 960, minHeight: 600)
                    .onOpenURL { app.handle(url: $0) }
            }
        }
        .defaultSize(width: 1380, height: 860)
        .commands {
            ToolbarCommands()
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
                Button("Buy Me a Pizza…") { openInBrowser(Support.pizzaURL) }
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Short Link") { if let ref = app.frontItem { app.copyShortLink(ref) } }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(app.frontItem == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { app.refresh() }
                    .keyboardShortcut("r")
                    .disabled(app.phase != .loggedIn)
                BlameCommand()
                Divider()
                TextZoomCommands()
                Divider()
            }
            CommandMenu("Go") {
                Button("Command Palette…") { app.showCommandPalette.toggle() }
                    .keyboardShortcut("k")
                    .disabled(app.phase != .loggedIn)
                Button("Open by Link…") { app.showOpenLink = true }
                    .keyboardShortcut("l")
                    .disabled(app.phase != .loggedIn || app.forge != nil)
                Button("Back") { if !app.detailPath.isEmpty { app.detailPath.removeLast() } }
                    .keyboardShortcut("[")
                    .disabled(app.detailPath.isEmpty)
                Divider()
                GoSectionCommands(app: app)
                Divider()
                Button("Go to Session…") { app.showQuickOpen = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(app.phase != .loggedIn)
                Button("New Agent Session") { app.newAgentSession() }
                    .keyboardShortcut("n")
                    .disabled(app.phase != .loggedIn)
                Button("Close Session") { if let tab = app.claude.selectedTab { app.claude.requestClose(tab) } }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(app.section != .claude || app.claude.selectedTab == nil)
                Button("Next Session") { app.claude.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                    .disabled(app.phase != .loggedIn || app.section != .claude)
                Button("Previous Session") { app.claude.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                    .disabled(app.phase != .loggedIn || app.section != .claude)
            }
        }

        MenuBarExtra {
            ThemedRoot { MenuBarView().environment(app) }
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)

        Window("Software Update", id: "update") {
            ThemedRoot { UpdateView() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Diagnostics", id: "diagnostics") {
            ThemedRoot { DiagnosticsView() }
        }
        .defaultSize(width: 980, height: 640)

        Settings {
            ThemedRoot { SettingsView().environment(app) }
        }
    }
}

struct GoSectionCommands: View {
    let app: AppModel

    var body: some View {
        let forge = app.forge != nil
        Group {
        Button("Review Requests") { app.section = .prs(.reviewRequested) }
            .keyboardShortcut("1")
            .disabled(forge && !app.forgeSupports(.prs(.reviewRequested)))
        Button(app.provider == .gitlab ? "My Merge Requests" : "My Pull Requests") { app.section = .prs(.mine) }
            .keyboardShortcut("2")
            .disabled(forge && !app.forgeSupports(.prs(.mine)))
        Button(forge ? (app.forgeCaps.inboxTitle ?? "Notifications") : "Notifications") { app.section = .notifications }
            .keyboardShortcut("3")
            .disabled(forge && !app.forgeSupports(.notifications))
        Button(app.provider.repositoriesTitle) { app.section = .repos }
            .keyboardShortcut("4")
            .disabled(forge && !app.forgeSupports(.repos))
        if !forge {
            Button("Projects") { app.section = .projects }.keyboardShortcut("5")
        }
        Button("Agents") { app.section = .claude }.keyboardShortcut("6")
        }
        .disabled(app.phase != .loggedIn)
    }
}

struct TextZoomCommands: View {
    private let zoom = TextZoom.shared

    var body: some View {
        Button("Actual Size") { zoom.reset() }
            .keyboardShortcut("0")
            .disabled(zoom.isDefault)
        Button("Zoom In") { zoom.zoomIn() }
            .keyboardShortcut("+")
            .disabled(!zoom.canZoomIn)
        Button("Zoom Out") { zoom.zoomOut() }
            .keyboardShortcut("-")
            .disabled(!zoom.canZoomOut)
    }
}

struct BlameFocusKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var blame: Binding<Bool>? {
        get { self[BlameFocusKey.self] }
        set { self[BlameFocusKey.self] = newValue }
    }
}

struct BlameCommand: View {
    @FocusedBinding(\.blame) private var blame

    var body: some View {
        Toggle("Blame", isOn: Binding(get: { blame ?? false }, set: { blame = $0 }))
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(blame == nil)
    }
}
