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

@main
struct PullYardWidgets: WidgetBundle {
    var body: some Widget {
        QueueWidget()
        CIActivityWidget()
    }
}
