import SwiftUI

struct MergeRequirementsList: View {
    let requirements: [MergeRequirement]
    var ownership: OwnershipSummary?
    let canPerform: (RequirementAction) -> Bool
    let perform: (RequirementAction) -> Void

    private var ordered: [MergeRequirement] {
        let rank: (RequirementState) -> Int = {
            switch $0 {
            case .missing: return 0
            case .pending: return 1
            case .unknown: return 2
            case .advisory: return 3
            case .satisfied: return 4
            }
        }
        return requirements.enumerated()
            .sorted { (rank($0.element.state), $0.offset) < (rank($1.element.state), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ordered) { r in
                row(r)
            }
            if let ownership, !ownership.groups.isEmpty || !ownership.unowned.isEmpty {
                CodeOwnersSection(summary: ownership, onRequestReview: canPerform(.requestReview) ? { perform(.requestReview) } : nil)
                    .padding(.top, 4)
            }
        }
        .padding(.leading, 2)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Merge requirements")
    }

    private func row(_ r: MergeRequirement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(r.state))
                .foregroundStyle(color(r.state))
                .font(.syCaption.weight(.semibold))
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title)
                    .font(.syCallout)
                    .foregroundStyle(r.state == .satisfied ? Color.syMuted : Color.syText)
                if let detail = r.detail {
                    Text(detail).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let action = r.action, r.state != .satisfied, canPerform(action) {
                Button(title(action)) { perform(action) }
                    .font(.syCaption)
                    .buttonStyle(.link)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(spoken(r.state))
    }

    private func icon(_ s: RequirementState) -> String {
        switch s {
        case .satisfied: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .pending: return "clock.fill"
        case .unknown: return "questionmark.circle"
        case .advisory: return "info.circle"
        }
    }

    private func color(_ s: RequirementState) -> Color {
        switch s {
        case .satisfied: return .ghGreen
        case .missing: return .ghRed
        case .pending: return .ghYellow
        case .unknown, .advisory: return .syMuted
        }
    }

    private func spoken(_ s: RequirementState) -> String {
        switch s {
        case .satisfied: return "met"
        case .missing: return "blocking"
        case .pending: return "in progress"
        case .unknown: return "unknown"
        case .advisory: return "doesn’t block"
        }
    }

    private func title(_ a: RequirementAction) -> String {
        switch a {
        case .requestReview: return "Request review"
        case .showChecks: return "Show checks"
        case .showConversation: return "Show conversation"
        case .showConflicts: return "View conflicts"
        case .updateBranch: return "Update branch"
        case .readyForReview: return "Ready for review"
        }
    }
}
