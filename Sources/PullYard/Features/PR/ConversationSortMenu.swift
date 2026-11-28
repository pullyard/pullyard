import SwiftUI

struct ConversationSortMenu: View {
    @AppStorage(ConversationOrder.key) private var newestFirst = true
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            segment(newest: true, title: "Newest", icon: "arrow.down")
            segment(newest: false, title: "Oldest", icon: "arrow.up")
        }
        .padding(2)
        .background(Capsule().fill(Color.syLine.opacity(0.55)))
        .animation(Motion.quick, value: newestFirst)
        .fixedSize()
        .help("Comment order — applies to every pull request and issue")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment order")
    }

    private func segment(newest: Bool, title: String, icon: String) -> some View {
        let selected = newestFirst == newest
        return Button { newestFirst = newest } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.syCaption2.weight(.bold))
                Text(title)
            }
            .font(.syCaption.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.syText : Color.syMuted)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background {
                if selected {
                    Capsule()
                        .fill(Color.syAccent.opacity(0.18))
                        .matchedGeometryEffect(id: "sort", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) first")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
