import SwiftUI

struct CodeOwnersSection: View {
    let summary: OwnershipSummary
    let onRequestReview: (() -> Void)?

    private static let limit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Code owners").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syMuted)
                Text(summary.sourcePath).font(.syCaption.monospaced()).foregroundStyle(Color.syDim)
                Spacer(minLength: 8)
                if let onRequestReview, !summary.suggestions(excluding: []).isEmpty {
                    Button("Request owners", action: onRequestReview)
                        .font(.syCaption)
                        .buttonStyle(.link)
                }
            }
            ForEach(summary.groups.prefix(Self.limit)) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: group.satisfied ? "checkmark.circle.fill" : "person.2.circle")
                        .foregroundStyle(group.satisfied ? Color.ghGreen : Color.syMuted)
                        .font(.syCaption.weight(.semibold))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    owners(group.owners)
                    Text(files(group.files.count))
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .help(group.files.joined(separator: "\n"))
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
            if summary.groups.count > Self.limit {
                Text("+\(summary.groups.count - Self.limit) more owner groups")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .padding(.leading, 22)
            }
            if !summary.unowned.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(Color.syAmber)
                        .font(.syCaption.weight(.semibold))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    Text("\(files(summary.unowned.count)) without a code owner")
                        .font(.syCaption)
                        .foregroundStyle(Color.syMuted)
                        .help(summary.unowned.joined(separator: "\n"))
                }
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Code owners")
    }

    private func owners(_ list: [OwnerEntry]) -> some View {
        HStack(spacing: 6) {
            ForEach(list, id: \.handle) { o in
                Text("@" + o.handle)
                    .font(.syCallout)
                    .foregroundStyle(color(o.status))
                    .help("@\(o.handle): \(title(o.status))")
                    .accessibilityLabel("\(o.handle), \(title(o.status))")
            }
        }
    }

    private func files(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    private func color(_ s: OwnerStatus) -> Color {
        switch s {
        case .approved: return .ghGreen
        case .changesRequested: return .ghRed
        case .requested: return .ghYellow
        case .notRequested: return .syText
        }
    }

    private func title(_ s: OwnerStatus) -> String {
        switch s {
        case .approved: return "approved"
        case .changesRequested: return "changes requested"
        case .requested: return "review requested"
        case .notRequested: return "not requested"
        }
    }
}
