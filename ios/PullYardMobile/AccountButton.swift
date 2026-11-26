import SwiftUI

private struct AccountButton: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Button { router.showSettings = true } label: {
            AvatarView(url: model.user?.avatarUrl, size: 30, fallback: model.user?.login)
                .overlay(Circle().stroke(MobileTheme.line))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.pyPlain)
        .accessibilityLabel("Settings")
    }
}

extension View {
    func accountButton() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { AccountButton() }
        }
    }
}
