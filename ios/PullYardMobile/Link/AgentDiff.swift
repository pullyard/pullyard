import SwiftUI

enum AgentDiffBuilder {
    static func lines(for diff: PYLinkDiff) -> [DiffLine] {
        var result: [DiffLine] = []
        var id = 0
        func add(_ kind: DiffLine.Kind, _ text: String) {
            result.append(DiffLine(id: id, kind: kind, text: text, oldLine: nil, newLine: nil))
            id += 1
        }
        for (index, edit) in diff.edits.enumerated() {
            if diff.edits.count > 1 { add(.hunk, String(format: L("Change %d of %d"), index + 1, diff.edits.count)) }
            for (kind, text) in compare(split(edit.old), split(edit.new)) { add(kind, text) }
        }
        return result
    }

    static func counts(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .add }.count, lines.filter { $0.kind == .delete }.count)
    }

    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func compare(_ old: [String], _ new: [String]) -> [(DiffLine.Kind, String)] {
        let n = old.count, m = new.count
        guard n > 0 else { return new.map { (.add, $0) } }
        guard m > 0 else { return old.map { (.delete, $0) } }
        guard n * m <= 4_000_000 else { return old.map { (.delete, $0) } + new.map { (.add, $0) } }
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(DiffLine.Kind, String)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if old[i] == new[j] {
                out.append((.context, old[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                out.append((.delete, old[i])); i += 1
            } else {
                out.append((.add, new[j])); j += 1
            }
        }
        while i < n { out.append((.delete, old[i])); i += 1 }
        while j < m { out.append((.add, new[j])); j += 1 }
        return out
    }
}

struct AgentDiffSheet: View {
    let item: PYLinkItem
    let session: String
    @ObservedObject private var link = LinkClient.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mobile.diff.wrap") private var wrap = true
    @State private var diff: PYLinkDiff?
    @State private var lines: [DiffLine] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    PYEmptyState(title: "Couldn't load the change", message: error)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if diff == nil {
                    PullYardLoader(title: "Loading the change…", size: 56)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { DiffLineRow(line: $0, wrap: wrap) }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(BrandBackdrop())
            .navigationTitle((diff?.path ?? item.text).split(separator: "/").last.map(String.init) ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let diff {
                    let counts = AgentDiffBuilder.counts(lines)
                    HStack(spacing: 10) {
                        Text(diff.path).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 8)
                        Text("+\(counts.added)").foregroundStyle(MobileTheme.green)
                        Text("−\(counts.removed)").foregroundStyle(MobileTheme.red)
                    }
                    .mobileFont(size: 12, weight: .semibold, design: .monospaced)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { wrap.toggle() } label: { Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical") }
                        .accessibilityLabel(wrap ? "Don't wrap lines" : "Wrap lines")
                }
            }
        }
        .task {
            do {
                let loaded = try await link.diff(item, in: session)
                lines = AgentDiffBuilder.lines(for: loaded)
                diff = loaded
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
