import SwiftUI

enum SessionCost {
    static let budgetKey = "agent.sessionBudget"
    static let choices: [Double] = [0, 1, 2, 5, 10, 20, 50]

    static var budget: Double { UserDefaults.standard.double(forKey: budgetKey) }

    static func total(base: Double, reported: Double) -> Double {
        base + max(reported, 0)
    }

    static func overBudget(cost: Double, budget: Double, allowance: Double) -> Bool {
        budget > 0 && cost >= budget + allowance
    }

    static func nextAllowance(cost: Double, budget: Double) -> Double {
        guard budget > 0 else { return 0 }
        return max(cost - budget, 0) + budget
    }

    static func format(_ value: Double) -> String {
        value < 100 ? String(format: "$%.2f", value) : String(format: "$%.0f", value)
    }

    @MainActor
    static var billedPerUse: Bool {
        if ClaudeProfiles.shared.active.endpoint != nil { return true }
        guard let info = ClaudeAccountStore.shared.info else { return false }
        return info.subscription == nil && (info.method == "console" || info.method == "api_key" || (info.provider ?? "firstParty") != "firstParty")
    }
}

struct BudgetPausedBanner: View {
    let chat: ChatSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle.fill").foregroundStyle(Color.syAmber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session cost \(SessionCost.format(chat.totalCost)) reached your \(SessionCost.format(SessionCost.budget)) limit")
                    .font(.syCallout.weight(.medium))
                    .foregroundStyle(Color.syText)
                Text("New messages wait until you continue. Change the limit in Settings › Agents.")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
            }
            Spacer()
            Button("Continue (+\(SessionCost.format(SessionCost.budget)))") { chat.continuePastBudget() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Color.syAmber)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syAmber.opacity(0.1)))
    }
}
