import SwiftUI

enum CommandGroupKind: String, CaseIterable {
    case navigation = "Navigation"
    case pullRequest = "Pull request"
    case files = "Files changed"
    case agents = "Agents"
    case view = "View"
}

enum AppCommand: String, CaseIterable, Identifiable {
    case palette, openLink, sections, overview, back, forward, toggleSidebar, refresh, newWindow, lock
    case switchTab, writeReview, approve, merge, fixComments, openInBrowser, copyShortLink, sendComment, nextInQueue, previousInQueue
    case nextFile, nextHunk, nextComment, markViewed, wrapLines, splitView
    case newSession, goToSession, nextSession, previousSession, closeSession
    case textSize, actualSize, zoomIn, zoomOut, blame, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .palette: return "Command palette"
        case .openLink: return "Open by link"
        case .sections: return "Review requests, mine, notifications, repositories, projects, agents"
        case .overview: return "Overview"
        case .back: return "Back"
        case .forward: return "Forward"
        case .toggleSidebar: return "Show or hide the sidebar"
        case .refresh: return "Refresh"
        case .newWindow: return "Open in new window"
        case .lock: return "Lock now"
        case .switchTab: return "Switch tab"
        case .writeReview: return "Write review"
        case .approve: return "Approve"
        case .merge: return "Merge"
        case .fixComments: return "Fix review comments with agent"
        case .openInBrowser: return "Open in browser"
        case .copyShortLink: return "Copy short link"
        case .sendComment: return "Send comment"
        case .nextInQueue: return "Next in review queue"
        case .previousInQueue: return "Previous in review queue"
        case .nextFile: return "Next and previous file"
        case .nextHunk: return "Next and previous hunk"
        case .nextComment: return "Next and previous comment"
        case .markViewed: return "Mark file as viewed"
        case .wrapLines: return "Wrap lines"
        case .splitView: return "Split view"
        case .newSession: return "New agent session"
        case .goToSession: return "Go to session"
        case .nextSession: return "Next session"
        case .previousSession: return "Previous session"
        case .closeSession: return "Close session"
        case .textSize: return "Text size"
        case .actualSize: return "Actual size"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .blame: return "Blame"
        case .shortcuts: return "Keyboard shortcuts"
        }
    }

    var group: CommandGroupKind {
        switch self {
        case .palette, .openLink, .sections, .overview, .back, .forward, .toggleSidebar, .refresh, .newWindow, .lock: return .navigation
        case .switchTab, .writeReview, .approve, .merge, .fixComments, .openInBrowser, .copyShortLink, .sendComment, .nextInQueue, .previousInQueue: return .pullRequest
        case .nextFile, .nextHunk, .nextComment, .markViewed, .wrapLines, .splitView: return .files
        case .newSession, .goToSession, .nextSession, .previousSession, .closeSession: return .agents
        case .textSize, .actualSize, .zoomIn, .zoomOut, .blame, .shortcuts: return .view
        }
    }

    var shortcut: KeyboardShortcut? {
        switch self {
        case .palette: return KeyboardShortcut("k")
        case .openLink: return KeyboardShortcut("l")
        case .overview: return KeyboardShortcut("0", modifiers: [.command, .option])
        case .back: return KeyboardShortcut("[")
        case .forward: return KeyboardShortcut("]")
        case .toggleSidebar: return KeyboardShortcut("s", modifiers: [.command, .control])
        case .refresh: return KeyboardShortcut("r")
        case .newWindow: return KeyboardShortcut("o", modifiers: [.command, .option])
        case .lock: return KeyboardShortcut("l", modifiers: [.command, .control])
        case .writeReview: return KeyboardShortcut("r", modifiers: [.command, .shift])
        case .approve: return KeyboardShortcut("a", modifiers: [.command, .shift])
        case .merge: return KeyboardShortcut("m", modifiers: [.command, .shift])
        case .fixComments: return KeyboardShortcut("f", modifiers: [.command, .shift])
        case .openInBrowser: return KeyboardShortcut("o", modifiers: [.command, .shift])
        case .copyShortLink: return KeyboardShortcut("c", modifiers: [.command, .shift])
        case .sendComment: return KeyboardShortcut(.return)
        case .nextInQueue: return KeyboardShortcut(.downArrow, modifiers: [.command, .option])
        case .previousInQueue: return KeyboardShortcut(.upArrow, modifiers: [.command, .option])
        case .newSession: return KeyboardShortcut("n")
        case .goToSession: return KeyboardShortcut("k", modifiers: [.command, .shift])
        case .nextSession: return KeyboardShortcut("]", modifiers: [.command, .shift])
        case .previousSession: return KeyboardShortcut("[", modifiers: [.command, .shift])
        case .closeSession: return KeyboardShortcut("w", modifiers: [.command, .option])
        case .actualSize: return KeyboardShortcut("0")
        case .zoomIn: return KeyboardShortcut("+")
        case .zoomOut: return KeyboardShortcut("-")
        case .blame: return KeyboardShortcut("b", modifiers: [.command, .option])
        case .shortcuts: return KeyboardShortcut("/")
        case .sections, .switchTab, .nextFile, .nextHunk, .nextComment, .markViewed, .wrapLines, .splitView, .textSize: return nil
        }
    }

    var glyph: String {
        switch self {
        case .sections: return "⌘1 – ⌘6"
        case .switchTab: return "⌥⌘1 – ⌥⌘9"
        case .nextFile: return "N  P"
        case .nextHunk: return "]  ["
        case .nextComment: return "C  ⇧C"
        case .markViewed: return "V"
        case .wrapLines: return "W"
        case .splitView: return "S"
        case .textSize: return "⌘+  ⌘−  ⌘0"
        default: return shortcut.map(Self.glyph) ?? ""
        }
    }

    var inShortcutsList: Bool {
        switch self {
        case .overview, .actualSize, .zoomIn, .zoomOut, .shortcuts, .previousInQueue, .previousSession: return false
        default: return true
        }
    }

    var listTitle: String {
        switch self {
        case .back: return "Back and forward"
        case .nextInQueue: return "Next and previous in review queue"
        case .nextSession: return "Next and previous session"
        default: return title
        }
    }

    var listGlyph: String {
        switch self {
        case .back: return "⌘[  ⌘]"
        case .nextInQueue: return "⌥⌘↓  ⌥⌘↑"
        case .nextSession: return "⇧⌘]  ⇧⌘["
        default: return glyph
        }
    }

    static func glyph(_ shortcut: KeyboardShortcut) -> String {
        var out = ""
        let m = shortcut.modifiers
        if m.contains(.control) { out += "⌃" }
        if m.contains(.option) { out += "⌥" }
        if m.contains(.shift) { out += "⇧" }
        if m.contains(.command) { out += "⌘" }
        switch shortcut.key {
        case .return: out += "↩"
        case .upArrow: out += "↑"
        case .downArrow: out += "↓"
        case .leftArrow: out += "←"
        case .rightArrow: out += "→"
        case .escape: out += "⎋"
        case .tab: out += "⇥"
        case .delete: out += "⌫"
        case .space: out += "Space"
        default:
            let c = String(shortcut.key.character)
            out += c == "-" ? "−" : c.uppercased()
        }
        return out
    }

    static func listed(in group: CommandGroupKind) -> [AppCommand] {
        allCases.filter { $0.group == group && $0.inShortcutsList }
    }
}

extension View {
    @ViewBuilder
    func keyboardShortcut(_ command: AppCommand) -> some View {
        if let s = command.shortcut { keyboardShortcut(s) } else { self }
    }
}
