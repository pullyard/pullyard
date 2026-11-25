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
            VoyageLockScreen(context: context)
                .activityBackgroundTint(WidgetPalette.navy)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.url(context))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ShipGlyph(size: 38)
                        .rotationEffect(.degrees(state.failed > 0 && !state.isMerged ? -8 : 0))
                        .padding(.leading, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VoyageScore(state: state, large: true)
                        .padding(.trailing, 6).padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .privacySensitive()
                        Text("\(context.attributes.repo.split(separator: "/").last.map(String.init) ?? context.attributes.repo) #\(context.attributes.number)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        SeaLane(state: state).frame(height: 34)
                        Text(state.voyage)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(VoyageTone.color(state))
                    }
                    .padding(.horizontal, 6).padding(.bottom, 2)
                }
            } compactLeading: {
                ShipGlyph(size: 24)
                    .rotationEffect(.degrees(state.failed > 0 && !state.isMerged ? -8 : 0))
            } compactTrailing: {
                VoyageScore(state: state, large: false)
            } minimal: {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: state.isMerged ? 1 : max(0.08, state.progress / 0.9))
                        .stroke(VoyageTone.color(state), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    ShipGlyph(size: 13)
                }
                .padding(1)
            }
            .widgetURL(Self.url(context))
            .keylineTint(VoyageTone.color(state))
        }
    }

    private static func url(_ context: ActivityViewContext<CIActivityAttributes>) -> URL? {
        URL(string: "pullyard://pull/\(context.attributes.repo)/\(context.attributes.number)")
    }
}

private enum VoyageTone {
    static func color(_ state: CIActivityAttributes.ContentState) -> Color {
        if state.isMerged { return WidgetPalette.green }
        if state.failed > 0 { return WidgetPalette.red }
        if state.running > 0 { return WidgetPalette.sky }
        return WidgetPalette.green
    }
}

private struct VoyageScore: View {
    let state: CIActivityAttributes.ContentState
    let large: Bool

    var body: some View {
        Group {
            if state.isMerged {
                Image(systemName: "checkmark.circle.fill")
            } else if state.failed > 0 {
                Label("\(state.failed)", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            } else if state.running > 0 {
                Text("\(state.passed + state.skipped)/\(state.total)")
            } else {
                Image(systemName: "anchor")
            }
        }
        .font(.system(size: large ? 20 : 13, weight: .bold, design: .rounded).monospacedDigit())
        .foregroundStyle(VoyageTone.color(state))
    }
}

private struct SeaLane: View {
    let state: CIActivityAttributes.ContentState

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let shipWidth: CGFloat = 30
            let travel = width - shipWidth - 22
            let x = 8 + travel * state.progress
            let storm = state.failed > 0 && !state.isMerged
            ZStack(alignment: .topLeading) {
                WaveLine(phase: state.progress * 9, amplitude: storm ? 3.2 : 1.6)
                    .stroke(storm ? WidgetPalette.red.opacity(0.55) : WidgetPalette.sky.opacity(0.35), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(height: 10)
                    .offset(y: height - 10)
                Capsule()
                    .fill(LinearGradient(colors: [WidgetPalette.violet.opacity(0.0), WidgetPalette.violet.opacity(0.7), WidgetPalette.sky], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, x + 4), height: 3)
                    .offset(y: height - 6.5)
                Circle()
                    .fill(WidgetPalette.violet)
                    .frame(width: 7, height: 7)
                    .offset(x: 0, y: height - 8.5)
                Image(systemName: state.isMerged ? "checkmark.seal.fill" : "flag.checkered")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.isMerged ? WidgetPalette.green : .white.opacity(0.55))
                    .frame(width: 18)
                    .offset(x: width - 18, y: height - 22)
                ShipGlyph(size: shipWidth)
                    .rotationEffect(.degrees(storm ? -9 : 0), anchor: .bottom)
                    .offset(x: x, y: height - 26)
            }
        }
    }
}

private struct WaveLine: Shape {
    var phase: Double
    var amplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = max(Int(rect.width / 3), 2)
        for step in 0...steps {
            let x = rect.width * CGFloat(step) / CGFloat(steps)
            let y = rect.midY + sin(Double(x) / 9 + phase) * amplitude
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

private struct VoyageLockScreen: View {
    let context: ActivityViewContext<CIActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                PullYardLogoMark(progress: 1, size: 30, flatten: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.attributes.title)
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .privacySensitive()
                    Text("\(context.attributes.repo) #\(context.attributes.number)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VoyageScore(state: state, large: true)
            }
            SeaLane(state: state).frame(height: 40)
            HStack {
                Text(state.voyage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(VoyageTone.color(state))
                Spacer()
                Text(state.updated, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background {
            ZStack {
                LinearGradient(colors: [WidgetPalette.navyTop, WidgetPalette.navy], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [WidgetPalette.violet.opacity(0.26), .clear], center: .topLeading, startRadius: 0, endRadius: 220)
                RadialGradient(colors: [VoyageTone.color(state).opacity(0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 200)
            }
        }
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 82, alignment: .trailing)
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
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: 42)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 96, alignment: .trailing)
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
