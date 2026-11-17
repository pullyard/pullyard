import SwiftUI

struct ChatSearchState {
    var open = false
    var query = ""
    var index = 0

    func matches(in items: [ChatItem]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return items.compactMap { item in
            switch item {
            case .user(_, let text, _): return text.localizedCaseInsensitiveContains(needle) ? item.id : nil
            case .text(let t): return t.text.localizedCaseInsensitiveContains(needle) ? item.id : nil
            default: return nil
            }
        }
    }
}

struct ChatSearchBar: View {
    @Binding var state: ChatSearchState
    let matches: [String]
    let jump: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.syMuted)
            TextField("Find in conversation", text: $state.query)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($focused)
                .onSubmit { step(1) }
            Text(matches.isEmpty ? (state.query.isEmpty ? "" : "No results") : "\(min(state.index, matches.count - 1) + 1) of \(matches.count)")
                .font(.syCaption)
                .foregroundStyle(Color.syMuted)
                .monospacedDigit()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .help("Previous match")
                .accessibilityLabel("Previous match")
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(matches.isEmpty)
                .help("Next match")
                .accessibilityLabel("Next match")
            Button { state.open = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
                .accessibilityLabel("Close search")
        }
        .font(.syCallout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.syLine))
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: state.query) {
            state.index = max(0, matches.count - 1)
            if let id = matches.last { jump(id) }
        }
    }

    private func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        state.index = (min(state.index, matches.count - 1) + delta + matches.count) % matches.count
        jump(matches[state.index])
    }
}
