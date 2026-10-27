import SwiftUI

extension EnvironmentValues {
    @Entry var inEdgePanel = false
}

private struct ToolbarSearch: ViewModifier {
    @Environment(\.inEdgePanel) private var inEdgePanel
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if inEdgePanel {
            content
        } else {
            content.searchable(text: $text, placement: .toolbar, prompt: Text(prompt))
        }
    }
}

private struct PanelToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.inEdgePanel) private var inEdgePanel
    let items: Items

    func body(content: Content) -> some View {
        if inEdgePanel {
            content
        } else {
            content.toolbar { items }
        }
    }
}

private struct CustomizablePanelToolbar<Items: CustomizableToolbarContent>: ViewModifier {
    @Environment(\.inEdgePanel) private var inEdgePanel
    let id: String
    let items: Items

    func body(content: Content) -> some View {
        if inEdgePanel {
            content
        } else {
            content.toolbar(id: id) { items }
        }
    }
}

extension View {
    func toolbarSearch(text: Binding<String>, prompt: String) -> some View {
        modifier(ToolbarSearch(text: text, prompt: prompt))
    }

    func panelToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(PanelToolbar(items: items()))
    }

    func panelToolbar<Items: CustomizableToolbarContent>(id: String, @ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(CustomizablePanelToolbar(id: id, items: items()))
    }
}
