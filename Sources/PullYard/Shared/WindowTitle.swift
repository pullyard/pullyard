import SwiftUI

struct DetailTitle: Equatable {
    let key: String
    let title: String
    let subtitle: String
}

extension EnvironmentValues {
    @Entry var detailKey: String?
}

private struct ColumnTitle: ViewModifier {
    @Environment(AppModel.self) private var app
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        let front = app.frontTitle
        content
            .navigationTitle(front?.title ?? title)
            .navigationSubtitle(front?.subtitle ?? subtitle)
    }
}

private struct DetailTitleModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.detailKey) private var key
    @Environment(\.inEdgePanel) private var inEdgePanel
    let title: String
    let subtitle: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .onChange(of: DetailTitle(key: key ?? "", title: title, subtitle: subtitle), initial: true) { _, value in
                publish(value)
            }
            .onChange(of: app.frontDetailKey) { publish(DetailTitle(key: key ?? "", title: title, subtitle: subtitle)) }
    }

    private func publish(_ value: DetailTitle) {
        guard !inEdgePanel, key != nil, app.frontDetailKey == value.key, app.detailTitle != value else { return }
        app.detailTitle = value
    }
}

extension View {
    func columnTitle(_ title: String, subtitle: String = "") -> some View {
        modifier(ColumnTitle(title: title, subtitle: subtitle))
    }

    func detailTitle(_ title: String, subtitle: String = "") -> some View {
        modifier(DetailTitleModifier(title: title, subtitle: subtitle))
    }
}
