import SwiftUI

struct OutboxItem: Codable, Identifiable, Hashable {
    enum Kind: Codable, Hashable {
        case comment
        case reply(Int)
        case review(ReviewEvent)
    }
    var id = UUID()
    let key: PRKey
    let kind: Kind
    let body: String
    var createdAt = Date()
    var lastError: String?

    var summary: String {
        switch kind {
        case .comment: "Comment on \(key.repo) #\(key.number)"
        case .reply: "Reply on \(key.repo) #\(key.number)"
        case let .review(event): "\(event.title) \(key.repo) #\(key.number)"
        }
    }
}

struct OutboxQueued: LocalizedError {
    var errorDescription: String? { "Saved. PullYard will send it when you're back online." }
}

struct OutboxCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.outbox.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Waiting to send · \(model.outbox.count)", systemImage: "paperplane.circle.fill")
                        .mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.accent)
                    Spacer()
                    Button("Send now") { Task { await model.flushOutbox() } }
                        .mobileFont(size: 14, weight: .semibold)
                }
                ForEach(model.outbox) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.lastError == nil ? "clock" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.lastError == nil ? MobileTheme.muted : MobileTheme.amber)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.summary).mobileFont(size: 14, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                            Text(item.lastError ?? item.body).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(2)
                        }
                        Spacer()
                        Button { withAnimation { model.removeFromOutbox(item) } } label: {
                            Image(systemName: "trash").foregroundStyle(MobileTheme.red).pyHitArea(minSize: 32)
                        }
                        .buttonStyle(.pyPlain)
                        .accessibilityLabel("Delete queued item")
                    }
                }
            }
            .padding(16)
            .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.large, style: .continuous), tint: MobileTheme.accent.opacity(0.08), fallback: MobileTheme.card)
        }
    }
}
