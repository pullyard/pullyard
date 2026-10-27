import AppKit
import SwiftUI

enum GitHubURL {
    private static let reserved: Set<String> = ["orgs", "settings", "notifications", "users", "marketplace", "features", "pulls", "issues", "search", "login", "logout", "apps", "sponsors", "topics", "explore", "new", "codespaces", "organizations", "enterprise", "about", "pricing", "collections", "trending"]

    static func parse(_ raw: String, allowShort: Bool = true) -> Route? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if allowShort, !s.contains("://"), let hash = s.firstIndex(of: "#") {
            let repoPart = String(s[..<hash])
            let num = Int(s[s.index(after: hash)...])
            if let num, let repo = RepoRef(full: repoPart), !repo.name.contains("/") {
                return .pr(ItemRef(repo: repo, number: num))
            }
            return nil
        }
        guard let url = URL(string: s.hasPrefix("http") ? s : "https://" + s), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "github.com" || host == "www.github.com" {
            guard parts.count >= 2, !reserved.contains(parts[0].lowercased()) else { return nil }
            let repo = RepoRef(owner: parts[0], name: parts[1])
            if parts.count >= 4 {
                if let n = Int(parts[3]) {
                    if parts[2] == "pull" { return .pr(ItemRef(repo: repo, number: n)) }
                    if parts[2] == "issues" { return .issue(ItemRef(repo: repo, number: n)) }
                }
                if parts[2] == "commit" { return .commit(repo, parts[3]) }
                return nil
            }
            if parts.count == 2 { return .repo(repo) }
            if parts.count == 3, parts[2] == "pulls" || parts[2] == "issues" { return .repo(repo) }
            return nil
        }
        if host == "api.github.com", parts.count >= 5, parts[0] == "repos", let n = Int(parts[4]) {
            let repo = RepoRef(owner: parts[1], name: parts[2])
            if parts[3] == "pulls" { return .pr(ItemRef(repo: repo, number: n)) }
            if parts[3] == "issues" { return .issue(ItemRef(repo: repo, number: n)) }
        }
        return nil
    }
}

enum Fmt {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = .app
        f.unitsStyle = .short
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func rel(_ date: Date?) -> String {
        guard let date else { return "" }
        if abs(date.timeIntervalSinceNow) < 45 { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

enum Support {
    static let pizzaURL = "https://checkout.dodopayments.com/buy/pdt_0NpmyolvMAwxrA4eQBgpO?quantity=1"
}

func openInBrowser(_ s: String?) {
    guard let s, let u = URL(string: s) else { return }
    LinkBrowser.open(u)
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static var ghGreen: Color { .syGreen }
    static var ghPurple: Color { .syViolet }
    static var ghRed: Color { .syRed }
    static var ghYellow: Color { .syAmber }
}

enum VisualState {
    case open, draft, merged, closed, issueOpen, completed, notPlanned

    static func pr(state: String, draft: Bool) -> VisualState {
        switch state {
        case "MERGED": return .merged
        case "CLOSED": return .closed
        default: return draft ? .draft : .open
        }
    }

    static func issue(state: String, reason: String?) -> VisualState {
        guard state == "CLOSED" else { return .issueOpen }
        return reason == "NOT_PLANNED" ? .notPlanned : .completed
    }

    var color: Color {
        switch self {
        case .open, .issueOpen: return .ghGreen
        case .draft, .notPlanned: return .secondary
        case .merged, .completed: return .ghPurple
        case .closed: return .ghRed
        }
    }

    var icon: String {
        switch self {
        case .open: return "arrow.triangle.pull"
        case .draft: return "pencil.circle"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark.circle"
        case .issueOpen: return "smallcircle.filled.circle"
        case .completed: return "checkmark.circle"
        case .notPlanned: return "slash.circle"
        }
    }

    var title: String {
        switch self {
        case .open, .issueOpen: return "Open"
        case .draft: return "Draft"
        case .merged: return "Merged"
        case .closed: return "Closed"
        case .completed: return "Completed"
        case .notPlanned: return "Not planned"
        }
    }
}

struct Avatar: View {
    let url: String?
    var size: CGFloat = 20
    var ring = false

    var body: some View {
        AsyncImage(url: resolved) { image in
            image.resizable().interpolation(.medium)
        } placeholder: {
            Circle().fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { if ring { Circle().strokeBorder(Color.syLineStrong, lineWidth: 0.5) } }
    }

    private var resolved: URL? {
        guard let url, var c = URLComponents(string: url) else { return nil }
        let px = Int(size * 2)
        var items = c.queryItems?.filter { $0.name != "s" } ?? []
        items.append(URLQueryItem(name: "s", value: "\(px)"))
        c.queryItems = items
        return c.url
    }
}

struct StateBadge: View {
    let state: VisualState
    var compact = false

    var body: some View {
        if compact {
            Image(systemName: state.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(state.color.opacity(0.15)))
                .help(state.title)
                .accessibilityLabel(state.title)
        } else {
            Label(state.title, systemImage: state.icon)
                .font(.syCallout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(state.color == .secondary ? Color.sySlate : state.color))
        }
    }
}

struct LabelChip: View {
    let label: LabelInfo

    var body: some View {
        let c = Color(hex: label.color)
        Text(label.name)
            .font(.syCaption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(c.opacity(0.22)))
            .overlay(Capsule().stroke(c.opacity(0.7), lineWidth: 0.5))
    }
}

struct CIIcon: View {
    let state: String?

    var body: some View {
        switch state {
        case "SUCCESS": Image(systemName: "checkmark").foregroundStyle(Color.ghGreen).help("Checks passed").accessibilityLabel("Checks passed")
        case "FAILURE", "ERROR": Image(systemName: "xmark").foregroundStyle(Color.ghRed).help("Checks failed").accessibilityLabel("Checks failed")
        case "PENDING", "EXPECTED": Image(systemName: "circle.dotted").foregroundStyle(Color.ghYellow).help("Checks running").accessibilityLabel("Checks running")
        default: EmptyView()
        }
    }
}

struct OutcomeIcon: View {
    let outcome: CheckOutcome

    var body: some View {
        switch outcome {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.ghGreen).accessibilityLabel("Passed")
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ghRed).accessibilityLabel("Failed")
        case .pending: Image(systemName: "clock.fill").foregroundStyle(Color.ghYellow).accessibilityLabel("Pending")
        case .neutral: Image(systemName: "minus.circle.fill").foregroundStyle(Color.syMuted).accessibilityLabel("Neutral")
        case .skipped: Image(systemName: "arrow.uturn.right.circle").foregroundStyle(Color.syMuted).accessibilityLabel("Skipped")
        }
    }
}

struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(Color.ghGreen)
            Text("−\(deletions)").foregroundStyle(Color.ghRed)
        }
        .font(.syCaption.monospacedDigit())
        .fixedSize()
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            IconTile(systemImage: "exclamationmark.triangle.fill", color: .syAmber, size: 44)
            Text(message).multilineTextAlignment(.center).textSelection(.enabled).foregroundStyle(Color.syMuted)
            if let retry { Button("Retry", action: retry) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LoadingView: View {
    @State private var visible = false

    var body: some View {
        PullYardLoader(size: 48)
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(nanoseconds: 180_000_000)
                withAnimation(Motion.fade) { visible = true }
            }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(attributed).textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct ComposerBox: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 60

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.syBody)
                .scrollContentBackground(.hidden)
                .padding(4)
                .accessibilityLabel(placeholder)
            if text.isEmpty {
                Text(placeholder).foregroundStyle(Color.syDim).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .frame(minHeight: minHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.sySunken))
    }
}

struct DrawnLogoMark: View {
    var key: String
    var size: CGFloat
    var duration: Double
    private static var drawn: Set<String> = []
    @State private var start = Date()
    @State private var done: Bool

    init(key: String = "", size: CGFloat = 56, duration: Double = 1.4) {
        self.key = key
        self.size = size
        self.duration = duration
        _done = State(initialValue: Motion.reduced || Self.drawn.contains(key))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: done)) { context in
            PullYardLogoMark(progress: done ? 1 : eased(context.date.timeIntervalSince(start) / duration), size: size)
        }
        .task {
            guard !done else { return }
            guard Self.drawn.insert(key).inserted else {
                done = true
                return
            }
            start = Date()
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            done = true
        }
    }

    private func eased(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

struct ListEmptyNote: View {
    var title = "Nothing here"
    var message: String?
    var filter = ""
    var compact = false
    var clear: (() -> Void)?
    var actionTitle: String?
    var action: (() -> Void)?

    private var filtering: Bool { !filter.isEmpty }

    var body: some View {
        if compact { inline } else { centered }
    }

    private var inline: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(filtering ? "No matches for “\(filter)”" : title).font(.syCallout).foregroundStyle(Color.syMuted)
            if !filtering, let message {
                Text(message).font(.syCaption).foregroundStyle(Color.syDim)
            }
            if filtering, let clear {
                Button("Clear filter", action: clear).buttonStyle(.link).font(.syCaption)
            }
        }
        .padding(.vertical, 4)
    }

    private var centered: some View {
        VStack(spacing: 12) {
            if filtering {
                IconTile(systemImage: "magnifyingglass", color: .syMuted, size: 44)
            } else {
                DrawnLogoMark(key: title, size: 64)
            }
            VStack(spacing: 4) {
                Text(filtering ? "No matches for “\(filter)”" : title)
                    .font(.syBody.weight(.semibold))
                    .foregroundStyle(Color.syText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let detail = filtering ? "Try a different search." : message {
                    Text(detail).font(.syCallout).foregroundStyle(Color.syMuted)
                }
            }
            .multilineTextAlignment(.center)
            if filtering, let clear {
                Button("Clear filter", action: clear).buttonStyle(.bordered).controlSize(.small)
            } else if !filtering, let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small)
            }
        }
        .frame(maxWidth: 300)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }
}

struct ListErrorNote: View {
    let message: String
    var centered = false
    var retry: (() async -> Void)?

    var body: some View {
        if centered {
            VStack(spacing: 12) {
                IconTile(systemImage: "exclamationmark.triangle.fill", color: .syRed, size: 44)
                VStack(spacing: 4) {
                    Text("Couldn’t load").font(.syBody.weight(.semibold)).foregroundStyle(Color.syText)
                    Text(message).font(.syCallout).foregroundStyle(Color.syMuted).textSelection(.enabled)
                }
                .multilineTextAlignment(.center)
                if let retry {
                    Button("Retry") { Task { await retry() } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            .frame(maxWidth: 320)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.syRed).accessibilityHidden(true)
                Text(message).font(.syCaption).foregroundStyle(Color.syRed).textSelection(.enabled)
                Spacer(minLength: 4)
                if let retry {
                    Button("Retry") { Task { await retry() } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct CommentSendButton: View {
    let text: String
    let busy: Bool
    let action: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(busy ? "Sending…" : "Comment")
            }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .tint(empty && !busy ? Color.sySlate : nil)
        .disabled(empty || busy)
        .help(empty ? "Write a comment to send it" : "Send comment (⌘↩)")
    }
}

func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let u = error as? URLError, u.code == .cancelled { return true }
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
}
