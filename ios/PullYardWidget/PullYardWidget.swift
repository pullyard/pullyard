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
                if let unread = entry.snapshot?.unread, unread > 0 {
                    Label("\(unread)", systemImage: "tray.full.fill").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
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

@main
struct PullYardWidgets: WidgetBundle {
    var body: some Widget { QueueWidget() }
}
