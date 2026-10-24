import AppKit
import SwiftUI

struct ExternalApp: Identifiable, Hashable {
    enum Kind { case editor, terminal, finder }
    let id: String
    let name: String
    let kind: Kind

    static let known: [ExternalApp] = [
        ExternalApp(id: "com.microsoft.VSCode", name: "VS Code", kind: .editor),
        ExternalApp(id: "com.todesktop.230313mzl4w4u92", name: "Cursor", kind: .editor),
        ExternalApp(id: "com.exafunction.windsurf", name: "Windsurf", kind: .editor),
        ExternalApp(id: "dev.zed.Zed", name: "Zed", kind: .editor),
        ExternalApp(id: "com.sublimetext.4", name: "Sublime Text", kind: .editor),
        ExternalApp(id: "com.panic.Nova", name: "Nova", kind: .editor),
        ExternalApp(id: "com.jetbrains.intellij", name: "IntelliJ IDEA", kind: .editor),
        ExternalApp(id: "com.jetbrains.WebStorm", name: "WebStorm", kind: .editor),
        ExternalApp(id: "com.jetbrains.pycharm", name: "PyCharm", kind: .editor),
        ExternalApp(id: "com.google.android.studio", name: "Android Studio", kind: .editor),
        ExternalApp(id: "com.apple.dt.Xcode", name: "Xcode", kind: .editor),
        ExternalApp(id: "com.apple.Terminal", name: "Terminal", kind: .terminal),
        ExternalApp(id: "com.googlecode.iterm2", name: "iTerm", kind: .terminal),
        ExternalApp(id: "com.mitchellh.ghostty", name: "Ghostty", kind: .terminal),
        ExternalApp(id: "dev.warp.Warp-Stable", name: "Warp", kind: .terminal),
        ExternalApp(id: "com.apple.finder", name: "Finder", kind: .finder),
    ]

    @MainActor static let installed: [ExternalApp] = known.filter { $0.kind == .finder || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    @MainActor private static var icons: [String: NSImage] = [:]

    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    @MainActor var icon: NSImage? {
        if let cached = Self.icons[id] { return cached }
        guard let url else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        Self.icons[id] = image
        return image
    }

    @MainActor func open(_ folder: String) {
        let target = URL(fileURLWithPath: folder)
        if kind == .finder {
            NSWorkspace.shared.activateFileViewerSelecting([target])
            return
        }
        guard let url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([target], withApplicationAt: url, configuration: config)
    }
}

struct OpenInMenu: View {
    let folder: String
    @AppStorage("agents.openIn") private var preferred = ""

    private var apps: [ExternalApp] { ExternalApp.installed }
    private var primary: ExternalApp? {
        apps.first { $0.id == preferred } ?? apps.first { $0.kind == .editor } ?? apps.first
    }

    var body: some View {
        Menu {
            section("Editors", .editor)
            section("Terminals", .terminal)
            Divider()
            if let finder = apps.first(where: { $0.kind == .finder }) { item(finder) }
        } label: {
            HStack(spacing: 5) {
                if let primary, let icon = primary.icon { Image(nsImage: icon) } else { Image(systemName: "arrow.up.forward.app") }
                Text(primary?.name ?? "Open")
            }
        } primaryAction: {
            primary?.open(folder)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Open the project in \(primary?.name ?? "another app") — click the arrow for more")
    }

    @ViewBuilder
    private func section(_ title: String, _ kind: ExternalApp.Kind) -> some View {
        let list = apps.filter { $0.kind == kind }
        if !list.isEmpty {
            Section(title) { ForEach(list) { item($0) } }
        }
    }

    private func item(_ app: ExternalApp) -> some View {
        Button {
            preferred = app.id
            app.open(folder)
        } label: {
            if let icon = app.icon { Label { Text(app.name) } icon: { Image(nsImage: icon) } } else { Text(app.name) }
        }
    }
}
