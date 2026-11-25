import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct QueueEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct QueueProvider: TimelineProvider {
    func placeholder(in context: Context) -> QueueEntry { QueueEntry(date: .now, snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (QueueEntry) -> Void) {
        completion(QueueEntry(date: .now, snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QueueEntry>) -> Void) {
        completion(Timeline(entries: [QueueEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .after(Date(timeIntervalSinceNow: 30 * 60))))
    }
}

private enum WidgetPalette {
    static let navy = Color(red: 0.047, green: 0.071, blue: 0.125)
    static let navyTop = Color(red: 0.102, green: 0.145, blue: 0.251)
    static let coral = Color(red: 0.941, green: 0.459, blue: 0.388)
    static let sky = Color(red: 0.357, green: 0.722, blue: 0.925)
    static let violet = Color(red: 0.631, green: 0.576, blue: 0.961)
    static let green = Color(red: 0.384, green: 0.769, blue: 0.561)
    static let amber = Color(red: 0.929, green: 0.725, blue: 0.333)
    static let red = Color(red: 0.933, green: 0.478, blue: 0.431)

    static func ci(_ state: String?) -> (String, Color)? {
        switch state?.uppercased() {
        case "SUCCESS": ("checkmark.circle.fill", green)
        case "FAILURE", "ERROR": ("xmark.circle.fill", red)
        case "PENDING", "EXPECTED": ("clock.fill", amber)
        default: nil
        }
    }
}

struct QueueWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QueueEntry

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: Text("\(entry.snapshot?.needsReview ?? 0) to review")
        case .systemMedium, .systemLarge: medium
        default: small
        }
    }

    private var count: Int { entry.snapshot?.needsReview ?? 0 }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(WidgetPalette.sky)
                Spacer()
                RefreshButton()
            }
            Spacer()
            Text("\(count)").font(.system(size: 46, weight: .bold, design: .rounded)).foregroundStyle(count > 0 ? WidgetPalette.coral : .white).contentTransition(.numericText())
            Text(count == 1 ? "review waiting" : "reviews waiting").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            if let updated = entry.snapshot?.updated {
                Text(updated, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
        }
        .widgetURL(URL(string: "pullyard://queue"))
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(count)").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(count > 0 ? WidgetPalette.coral : .white)
                Text("to review").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("My PRs \(entry.snapshot?.myOpen ?? 0)").font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.sky)
                RefreshButton()
            }
            if let items = entry.snapshot?.items, !items.isEmpty {
                ForEach(items.prefix(3)) { item in
                    Link(destination: item.url ?? URL(string: "pullyard://queue")!) {
                        HStack(spacing: 8) {
                            if let ci = WidgetPalette.ci(item.ci) { Image(systemName: ci.0).foregroundStyle(ci.1).font(.caption) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                Text("\(item.repo) #\(item.number)").font(.caption2).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            } else {
                Spacer()
                Text("Calm waters. Nothing needs your review.").font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "arrow.triangle.pull").font(.caption2)
                Text("\(count)").font(.system(.title3, design: .rounded).weight(.bold))
            }
        }
        .widgetURL(URL(string: "pullyard://queue"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("\(count) to review", systemImage: "arrow.triangle.pull").font(.headline)
            if let first = entry.snapshot?.items.first {
                Text(first.title).font(.caption).lineLimit(1)
            } else {
                Text("Nothing waiting").font(.caption)
            }
        }
        .widgetURL(URL(string: "pullyard://queue"))
    }
}

struct QueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PullYardQueue", provider: QueueProvider()) { entry in
            QueueWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    ZStack {
                        LinearGradient(colors: [WidgetPalette.navyTop, WidgetPalette.navy], startPoint: .top, endPoint: .bottom)
                        Circle().fill(WidgetPalette.violet.opacity(0.35)).blur(radius: 40).offset(x: -60, y: -50)
                        Circle().fill(WidgetPalette.sky.opacity(0.25)).blur(radius: 40).offset(x: 70, y: -30)
                    }
                }
        }
        .configurationDisplayName("Review queue")
        .description("Pull requests waiting for your review.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshQueueIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(.white.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

struct CIActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CIActivityAttributes.self) { context in
            CILockScreenView(context: context)
                .activityBackgroundTint(WidgetPalette.navy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "pullyard://pull/\(context.attributes.repo)/\(context.attributes.number)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("#\(context.attributes.number)", systemImage: "arrow.triangle.pull").font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.sky)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CIStateIcon(state: context.state).font(.title3)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        CIProgressBar(state: context.state)
                        Text(context.state.headline).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(WidgetPalette.sky)
            } compactTrailing: {
                CIStateIcon(state: context.state)
            } minimal: {
                CIStateIcon(state: context.state)
            }
            .widgetURL(URL(string: "pullyard://pull/\(context.attributes.repo)/\(context.attributes.number)"))
        }
    }
}

private struct CIStateIcon: View {
    let state: CIActivityAttributes.ContentState
    var body: some View {
        if state.failed > 0 {
            Image(systemName: "xmark.circle.fill").foregroundStyle(WidgetPalette.red)
        } else if state.running > 0 {
            Image(systemName: "clock.fill").foregroundStyle(WidgetPalette.amber)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(WidgetPalette.green)
        }
    }
}

private struct CIProgressBar: View {
    let state: CIActivityAttributes.ContentState
    var body: some View {
        GeometryReader { geo in
            let total = CGFloat(max(state.total, 1))
            HStack(spacing: 2) {
                if state.failed > 0 { Capsule().fill(WidgetPalette.red).frame(width: geo.size.width * CGFloat(state.failed) / total) }
                if state.running > 0 { Capsule().fill(WidgetPalette.amber).frame(width: geo.size.width * CGFloat(state.running) / total) }
                if state.passed > 0 { Capsule().fill(WidgetPalette.green).frame(width: geo.size.width * CGFloat(state.passed) / total) }
                if state.skipped > 0 { Capsule().fill(Color.gray.opacity(0.5)).frame(width: geo.size.width * CGFloat(state.skipped) / total) }
            }
        }
        .frame(height: 6)
    }
}

private struct CILockScreenView: View {
    let context: ActivityViewContext<CIActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CIStateIcon(state: context.state).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(context.attributes.repo) #\(context.attributes.number)").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text(context.state.updated, style: .relative).font(.caption2).foregroundStyle(.white.opacity(0.5))
            }
            CIProgressBar(state: context.state)
            Text(context.state.headline).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(16)
    }
}

struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentLockScreenView(context: context)
                .activityBackgroundTint(WidgetPalette.navy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.url(context))
        } dynamicIsland: { context in
            let phase = context.state.phase
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PullYardLogoMark(progress: 1, size: 40, flatten: false).padding(.leading, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentTimer(state: context.state)
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 6).padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .privacySensitive()
                        AgentPhasePill(phase: phase, compact: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        AgentWake(phase: phase)
                        AgentDetailLine(state: context.state, stale: context.isStale)
                        AgentPermissionButtons(session: context.attributes.session, state: context.state)
                    }
                    .padding(.horizontal, 6).padding(.top, 6)
                }
            } compactLeading: {
                PullYardLogoMark(progress: 1, size: 24, flatten: false)
            } compactTrailing: {
                if phase == .working {
                    AgentTimer(state: context.state)
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AgentPhaseStyle.color(phase))
                        .frame(maxWidth: 46)
                } else {
                    Image(systemName: AgentPhaseStyle.symbol(phase)).font(.system(size: 13, weight: .bold)).foregroundStyle(AgentPhaseStyle.color(phase))
                }
            } minimal: {
                ZStack {
                    Circle().stroke(AgentPhaseStyle.color(phase).opacity(0.9), lineWidth: 2)
                    PullYardLogoMark(progress: 1, size: 15, flatten: false)
                }
            }
            .widgetURL(Self.url(context))
            .keylineTint(AgentPhaseStyle.color(phase))
        }
    }

    private static func url(_ context: ActivityViewContext<AgentActivityAttributes>) -> URL? {
        URL(string: "pullyard://agent/\(context.attributes.session)")
    }
}

private enum AgentPhaseStyle {
    typealias Phase = AgentActivityAttributes.ContentState.Phase

    static func color(_ phase: Phase) -> Color {
        switch phase {
        case .working: WidgetPalette.coral
        case .waiting: WidgetPalette.amber
        case .done: WidgetPalette.green
        case .stopped: Color(white: 0.62)
        case .failed: WidgetPalette.red
        }
    }

    static func symbol(_ phase: Phase) -> String {
        switch phase {
        case .working: "sparkles"
        case .waiting: "hand.raised.fill"
        case .done: "checkmark"
        case .stopped: "stop.fill"
        case .failed: "exclamationmark"
        }
    }
}

private struct AgentPhasePill: View {
    let phase: AgentActivityAttributes.ContentState.Phase
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: AgentPhaseStyle.symbol(phase)).font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(LocalizedStringKey(label)).font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(AgentPhaseStyle.color(phase))
        .padding(.horizontal, compact ? 0 : 9).padding(.vertical, compact ? 0 : 4)
        .background {
            if !compact { Capsule().fill(AgentPhaseStyle.color(phase).opacity(0.15)) }
        }
    }

    private var label: String {
        switch phase {
        case .working: "Working"
        case .waiting: "Needs you"
        case .done: "Done"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

private struct AgentTimer: View {
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if let finished = state.finished {
            Text(timerInterval: state.started...max(finished, state.started), pauseTime: max(finished, state.started), countsDown: false, showsHours: false)
        } else {
            Text(timerInterval: state.started...Date.distantFuture, countsDown: false, showsHours: false)
        }
    }
}

private struct AgentWake: View {
    let phase: AgentActivityAttributes.ContentState.Phase

    var body: some View {
        let active = phase == .working || phase == .waiting
        Capsule()
            .fill(active ? AnyShapeStyle(LinearGradient(colors: [WidgetPalette.violet, WidgetPalette.sky, AgentPhaseStyle.color(phase)], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(AgentPhaseStyle.color(phase).opacity(0.55)))
            .frame(height: 3)
            .opacity(active ? 1 : 0.8)
    }
}

private struct AgentPermissionButtons: View {
    let session: String
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        if state.phase == .waiting, let request = state.permissionID {
            HStack(spacing: 10) {
                Button(intent: AgentPermissionIntent(session: session, request: request, allow: false)) {
                    Label("Deny", systemImage: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Capsule().fill(.white.opacity(0.14)))
                Button(intent: AgentPermissionIntent(session: session, request: request, allow: true)) {
                    Label("Allow", systemImage: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WidgetPalette.navy)
                .background(Capsule().fill(WidgetPalette.green))
            }
        }
    }
}

private struct AgentDetailLine: View {
    let state: AgentActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.phase == .working ? "chevron.right" : "text.quote")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.4))
            Text(stale && state.finished == nil ? "Open PullYard for the latest" : state.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .privacySensitive()
            Spacer(minLength: 6)
            if state.steps > 0 {
                Text("\(state.steps)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .accessibilityLabel("\(state.steps) steps")
            }
        }
    }
}

private struct AgentLockScreenView: View {
    let context: ActivityViewContext<AgentActivityAttributes>

    var body: some View {
        let phase = context.state.phase
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PullYardLogoMark(progress: 1, size: 34, flatten: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PullYard").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(context.attributes.mac).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                AgentPhasePill(phase: phase)
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(context.attributes.title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .privacySensitive()
                Spacer(minLength: 8)
                AgentTimer(state: context.state)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100, alignment: .trailing)
            }
            AgentWake(phase: phase)
            AgentDetailLine(state: context.state, stale: context.isStale)
            AgentPermissionButtons(session: context.attributes.session, state: context.state)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background {
            ZStack {
                LinearGradient(colors: [WidgetPalette.navyTop, WidgetPalette.navy], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [WidgetPalette.violet.opacity(0.28), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                RadialGradient(colors: [WidgetPalette.sky.opacity(0.18), .clear], center: .topTrailing, startRadius: 0, endRadius: 200)
                RadialGradient(colors: [AgentPhaseStyle.color(phase).opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 180)
            }
        }
    }
}

@main
struct PullYardWidgets: WidgetBundle {
    var body: some Widget {
        QueueWidget()
        CIActivityWidget()
        AgentActivityWidget()
    }
}
