import Foundation
import SwiftUI

enum ProcessMemory {
    struct Entry {
        let ppid: pid_t
        let rss: Int
    }

    static func snapshot() -> [pid_t: Entry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,rss="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak p] in
            if p?.isRunning == true { p?.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var map: [pid_t: Entry] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]), let rss = Int(f[2]) else { continue }
            map[pid] = Entry(ppid: ppid, rss: rss * 1024)
        }
        return map
    }

    static func treeBytes(_ root: pid_t, in snap: [pid_t: Entry]) -> Int {
        guard root > 0, let rootEntry = snap[root] else { return 0 }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, e) in snap { children[e.ppid, default: []].append(pid) }
        var total = rootEntry.rss
        var stack = children[root] ?? []
        var seen: Set<pid_t> = [root]
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted, let e = snap[pid] else { continue }
            total += e.rss
            stack += children[pid] ?? []
        }
        return total
    }

    static func format(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f ", mb / 1024) + "GB" : "\(Int(mb.rounded())) " + "MB"
    }
}

enum ProjectPalette {
    private static let colors: [Color] = [
        .sySky,
        .syViolet,
        .syCoral,
        Color(nsColor: .systemOrange),
        .syTeal,
        .syGreen,
        .syIndigo,
        .syAmber
    ]

    static func color(for path: String) -> Color {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return colors[Int(h % UInt64(colors.count))]
    }
}

enum BranchStyle {
    static func color(_ branch: String) -> Color {
        let b = branch.lowercased()
        if ["main", "master", "develop", "dev", "staging", "release"].contains(b) { return .sySlate }
        if b.hasPrefix("feat") || b.hasPrefix("feature") { return .syGreen }
        if b.hasPrefix("fix") || b.hasPrefix("hotfix") || b.hasPrefix("bug") { return .syAmber }
        if b.hasPrefix("chore") || b.hasPrefix("refactor") || b.hasPrefix("docs") { return .syTeal }
        if b.range(of: "^[a-z]+-[0-9]+", options: .regularExpression) != nil { return .syViolet }
        return .syMuted
    }
}

struct BranchTag: View {
    let name: String

    var body: some View {
        let c = BranchStyle.color(name)
        HStack(spacing: 3) {
            Image(systemName: "arrow.branch").imageScale(.small)
            Text(name).lineLimit(1).truncationMode(.middle)
        }
        .font(.syCaption)
        .foregroundStyle(c)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(c.opacity(0.12)))
    }
}

struct PRTag: View {
    let number: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.pull").imageScale(.small)
            Text("#\(number)")
        }
        .font(.syCaption.weight(.medium))
        .foregroundStyle(Color.syViolet)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.syViolet.opacity(0.12)))
    }
}

enum ClaudeTabState {
    case working, waiting, active, sleeping, stopped

    var color: Color {
        switch self {
        case .working: return .syMuted
        case .waiting: return .syAmber
        case .active: return .syMuted
        case .sleeping: return .syDim
        case .stopped: return .syDim
        }
    }

    var icon: String {
        switch self {
        case .working: return "bolt.fill"
        case .waiting: return "hand.raised.fill"
        case .active: return "circle.fill"
        case .sleeping: return "moon.zzz.fill"
        case .stopped: return "stop.circle"
        }
    }

    var title: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .active: return "Active"
        case .sleeping: return "Sleeping"
        case .stopped: return "Stopped"
        }
    }

    var help: String {
        switch self {
        case .sleeping: return "Process stopped, memory freed. A new message resumes the session."
        case .active: return "Process is running and uses memory. Sleeps after idle time."
        default: return title
        }
    }
}

struct TabStateBadge: View {
    let state: ClaudeTabState
    var memory: Int?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            if state == .working {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else {
                Image(systemName: state.icon).font(.system(size: state == .active ? 6 : 9))
            }
            if !compact {
                Text(state.title)
                if let memory, memory > 0, state != .sleeping {
                    Text("· " + ProcessMemory.format(memory)).foregroundStyle(Color.syMuted)
                }
            }
        }
        .font(.syCaption)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(state.color)
        .help(state.help + (memory.map { $0 > 0 ? " — " + ProcessMemory.format($0) : "" } ?? ""))
    }
}

enum SessionIndicator {
    case none, working, done, waiting

    @MainActor init(tab: ClaudeTab) {
        switch tab.state {
        case .waiting: self = .waiting
        case .working: self = .working
        default: self = tab.unread ? .done : .none
        }
    }

    @MainActor init(closed session: ClaudeSessionInfo, now: Date = Date()) {
        if now.timeIntervalSince(session.modified) < 15 { self = .working; return }
        self = SessionSeen.shared.isUnread(session.id, modified: session.modified) ? .done : .none
    }

    var help: String {
        switch self {
        case .none: return ""
        case .working: return "Claude is working"
        case .done: return "Finished — not viewed yet"
        case .waiting: return "Claude is waiting for you"
        }
    }
}

enum BrandMark {
    static let violet = Color(red: 0.655, green: 0.545, blue: 0.980)
    static let sky = Color(red: 0.220, green: 0.741, blue: 0.973)
    static let hullTop = Color(red: 0.984, green: 0.443, blue: 0.522)
    static let hullBottom = Color(red: 0.839, green: 0.122, blue: 0.306)
    static var branches: AngularGradient { AngularGradient(colors: [violet, sky, violet], center: .center) }
}

struct SessionIndicatorDot: View {
    let indicator: SessionIndicator

    var body: some View {
        Group {
            switch indicator {
            case .none:
                EmptyView()
            case .working:
                TimelineView(.animation(minimumInterval: 1 / 60, paused: Motion.reduced)) { context in
                    let angle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
                    ZStack {
                        Circle().stroke(BrandMark.violet.opacity(0.2), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: 0.34)
                            .stroke(LinearGradient(colors: [BrandMark.sky, BrandMark.violet], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(angle))
                    }
                }
                .frame(width: 10, height: 10)
            case .done:
                ZStack {
                    Circle().strokeBorder(BrandMark.branches, lineWidth: 2)
                    Circle().fill(LinearGradient(colors: [BrandMark.violet, BrandMark.sky], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 4, height: 4)
                }
                .frame(width: 10, height: 10)
            case .waiting:
                TimelineView(.animation(minimumInterval: 1 / 60, paused: Motion.reduced)) { context in
                    let t = Motion.reduced ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    let eased = 1 - pow(1 - t, 3)
                    ZStack {
                        Circle()
                            .fill(BrandMark.hullTop.opacity(0.3))
                            .scaleEffect(1 + 0.7 * eased)
                            .opacity(1 - eased)
                        Circle().fill(LinearGradient(colors: [BrandMark.hullTop, BrandMark.hullBottom], startPoint: .top, endPoint: .bottom))
                        Text("?").font(.system(size: 8, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    }
                }
                .frame(width: 12, height: 12)
            }
        }
        .frame(width: 14, height: 14)
        .help(indicator.help)
        .accessibilityLabel(indicator.help)
    }
}

@Observable
@MainActor
final class SessionSeen {
    static let shared = SessionSeen()
    private static let key = "agents.seen"
    private static let baselineKey = "agents.seenBaseline"
    private var seen: [String: Date]
    private let baseline: Date

    private init() {
        let d = UserDefaults.standard
        if let b = d.object(forKey: Self.baselineKey) as? Date {
            baseline = b
        } else {
            baseline = Date()
            d.set(baseline, forKey: Self.baselineKey)
        }
        seen = (d.dictionary(forKey: Self.key) as? [String: Date]) ?? [:]
    }

    func isUnread(_ id: String, modified: Date) -> Bool {
        modified > baseline && modified > (seen[id] ?? .distantPast).addingTimeInterval(2)
    }

    func mark(_ id: String) {
        guard !id.isEmpty else { return }
        seen[id] = Date()
        if seen.count > 600 {
            for (k, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - 500) { seen[k] = nil }
        }
        UserDefaults.standard.set(seen, forKey: Self.key)
    }
}

@Observable
@MainActor
final class AgentSessionPrefs {
    static let shared = AgentSessionPrefs()
    private(set) var pinned: [String]
    private(set) var titles: [String: String]
    private(set) var archived: Set<String>

    private init() {
        let d = UserDefaults.standard
        pinned = d.stringArray(forKey: "agents.pinned") ?? []
        titles = (d.dictionary(forKey: "agents.titles") as? [String: String]) ?? [:]
        archived = Set(d.stringArray(forKey: "agents.archived") ?? [])
    }

    func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    func togglePin(_ id: String) {
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) } else { pinned.insert(id, at: 0) }
        UserDefaults.standard.set(pinned, forKey: "agents.pinned")
    }

    func title(_ s: ClaudeSessionInfo) -> String { titles[s.id] ?? s.title }

    func rename(_ id: String, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        titles[id] = t.isEmpty ? nil : t
        UserDefaults.standard.set(titles, forKey: "agents.titles")
    }

    func isArchived(_ s: ClaudeSessionInfo) -> Bool { archived.contains(s.id) || s.archived }

    func setArchived(_ id: String, _ value: Bool) {
        if value { archived.insert(id); pinned.removeAll { $0 == id } } else { archived.remove(id) }
        UserDefaults.standard.set(Array(archived), forKey: "agents.archived")
        UserDefaults.standard.set(pinned, forKey: "agents.pinned")
    }
}
