import SwiftUI

struct TabItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let icon: String
    var badge: String?
    var badgeColor: Color = .secondary
    var badgeLabel: String?
}

struct TabStrip<ID: Hashable>: View {
    let items: [TabItem<ID>]
    @Binding var selection: ID
    var shortcuts = false
    @Namespace private var ns
    @State private var hovered: ID?
    @State private var available: CGFloat = 0
    @State private var fullWidth: CGFloat = 0

    var body: some View {
        let titles = fullWidth == 0 || available == 0 || fullWidth <= available
        strip(titles: titles)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            .onChange(of: items.map { "\($0.title)|\($0.badge ?? "")" }) { fullWidth = 0 }
            .animation(Motion.spring, value: selection)
    }

    private func strip(titles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = item.id == selection
                Button {
                    selection = item.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon).imageScale(.small)
                        if titles {
                            Text(item.title).lineLimit(1).fixedSize()
                        }
                        if let badge = item.badge {
                            Text(badge)
                                .font(.syCaption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(item.badgeColor)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(selected ? Color.syAccent.opacity(0.16) : Color.syLine))
                        }
                    }
                    .font(.syCallout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected || hovered == item.id ? Color.syText : Color.syMuted)
                    .padding(.horizontal, titles ? 12 : 10)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.syAccent.opacity(0.12))
                                .matchedGeometryEffect(id: titles ? "pill" : "pill.compact", in: ns)
                        } else if hovered == item.id {
                            Capsule().fill(Color.syText.opacity(0.06))
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if selected {
                            Capsule()
                                .fill(Color.syAccent)
                                .frame(width: 18, height: 3)
                                .shadow(color: Color.syAccent.opacity(0.7), radius: 4)
                                .matchedGeometryEffect(id: titles ? "underline" : "underline.compact", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(Motion.fade) { hovered = h ? item.id : (hovered == item.id ? nil : hovered) } }
                .modifier(OptionalShortcut(key: shortcuts && index < 9 ? Character("\(index + 1)") : nil))
                .help(shortcuts && index < 9 ? "\(item.title) (⌥⌘\(index + 1))" : item.title)
                .accessibilityLabel(item.badgeLabel.map { "\(item.title), \($0)" } ?? item.badge.map { "\(item.title), \($0)" } ?? item.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if titles { fullWidth = $0 + 16 } }
        .padding(.horizontal, 8)
    }
}

struct OptionalShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
        } else {
            content
        }
    }
}
