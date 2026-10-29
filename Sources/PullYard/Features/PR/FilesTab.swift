import SwiftUI

struct FilesTab: View {
    @Bindable var model: PRDetailModel
    @Environment(AppModel.self) private var app
    @State private var showList = true
    @State private var filter = ""
    @State private var navigator = DiffNavigator()
    @State private var splitFits = false
    @State private var focus = FileFocus()
    @State private var cache = DiffRowsCache()
    @AppStorage(DiffPrefs.wrapKey) private var wrap = true
    @AppStorage(DiffPrefs.splitKey) private var split = false

    var body: some View {
        Group {
            if model.filesLoaded {
                HStack(spacing: 0) {
                    if showList {
                        HStack(spacing: 0) {
                            FileListPane(model: model, focus: focus, filter: $filter, files: visibleFiles).frame(width: 260).surface(.list)
                            Divider()
                        }
                    }
                    VStack(spacing: 0) {
                        reviewBar
                        DiffRefreshHost(model: model) { diff }
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { measure(g.size.width) }
                            .onChange(of: g.size.width) { _, w in measure(w) }
                    })
                }
            } else if let e = model.filesError {
                ErrorStateView(message: e) { Task { await model.loadFiles(force: true) } }
            } else {
                LoadingView()
            }
        }
        .task { await model.loadFiles() }
    }

    private var splitAvailable: Bool { splitFits }

    private func measure(_ width: CGFloat) {
        let fits = width >= DiffPrefs.splitMinWidth - (splitFits ? 40 : 0)
        if fits != splitFits { splitFits = fits }
    }
    private var splitActive: Bool { split && splitAvailable }

    private var reviewOptions: DiffReviewOptions {
        DiffReviewOptions(wrap: wrap, split: splitActive, splitAvailable: splitAvailable) { key in perform(key) }
    }

    private var blameAction: ((DiffFile) -> Void)? {
        guard let head = model.filesOid ?? model.pr?.headRefOid else { return nil }
        let app = app
        let repo = model.ref.repo
        return { file in app.openCode(repo, ref: head, path: file.id, blame: true) }
    }

    private var visibleFiles: [DiffFile] {
        filter.isEmpty ? model.files : model.files.filter { $0.id.localizedCaseInsensitiveContains(filter) }
    }

    private var currentFile: String? {
        if let id = navigator.currentGroupID(), id.hasPrefix("h:") { return String(id.dropFirst(2)) }
        return visibleFiles.first?.id
    }

    @discardableResult
    private func perform(_ key: String) -> Bool {
        switch key {
        case "n": stepFile(1)
        case "p": stepFile(-1)
        case "]": navigator.jumpHunk(1)
        case "[": navigator.jumpHunk(-1)
        case "v":
            guard let path = currentFile else { return false }
            Task { await model.toggleViewed(path) }
        case "w": wrap.toggle()
        case "s":
            guard splitAvailable else { return false }
            split = !splitActive
        default: return false
        }
        return true
    }

    private func stepFile(_ step: Int) {
        let files = visibleFiles
        guard !files.isEmpty else { return }
        let index = currentFile.flatMap { current in files.firstIndex { $0.id == current } }
        let path = files[index.map { min(max($0 + step, 0), files.count - 1) } ?? 0].id
        navigator.scroll(to: "h:" + path)
        model.revealFile(path)
    }

    private var reviewBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                navButton("chevron.up", "Previous file", key: "P") { perform("p") }
                navButton("chevron.down", "Next file", key: "N") { perform("n") }
            }
            HStack(spacing: 2) {
                navButton("arrow.up.to.line", "Previous hunk", key: "[") { perform("[") }
                navButton("arrow.down.to.line", "Next hunk", key: "]") { perform("]") }
            }
            Spacer()
            Toggle("Wrap lines", isOn: $wrap)
                .toggleStyle(.checkbox)
                .help("Wrap long lines (W)")
                .accessibilityLabel("Wrap lines")
            Picker("Diff layout", selection: Binding(get: { splitActive }, set: { split = $0 })) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(!splitAvailable)
            .help(splitAvailable ? "Unified or side-by-side diff (S)" : "Widen the window to use split view")
            .accessibilityLabel("Diff layout")
        }
        .font(.syCaption)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.syLine).frame(height: 1) }
    }

    private func navButton(_ symbol: String, _ title: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .help("\(title) (\(key))")
        .accessibilityLabel(title)
    }

    private var diff: some View {
        let flat = model.flatRows(filter: filter)
        let key = "\(model.flatCacheKey)|\(splitActive)|\(wrap)|\(splitAvailable)|\(model.filesOid ?? "")"
        if key != cache.key {
            let built = tableRows(flat, split: splitActive)
            cache.key = key
            cache.version += 1
            cache.rows = built.rows
            cache.fileOf = built.fileOf
        }
        let fileOf = cache.fileOf
        let focus = focus
        return DiffTableView(
            rows: cache.rows,
            version: cache.version,
            scrollTarget: model.scrollTarget.map { "h:" + $0 },
            scrollToken: model.scrollToken,
            active: model.tab == .files,
            wrap: wrap,
            navigator: navigator,
            onTopGroup: { id in focus.current = id.flatMap { $0.hasPrefix("h:") ? String($0.dropFirst(2)) : nil } },
            onKey: { perform($0) },
            onComment: { id, line in
                guard let path = fileOf[id], let n = line.anchorLine else { return }
                model.composer = DiffAnchor(path: path, line: n, side: line.anchorSide)
            }
        )
    }

    private func tableRows(_ flat: [FlatDiffRow], split: Bool) -> (rows: [DiffTableRow], fileOf: [String: String]) {
        var rows: [DiffTableRow] = []
        rows.reserveCapacity(flat.count)
        var fileOf: [String: String] = [:]
        var ext = ""
        var segmentFile: DiffFile?
        var segment: [(line: DiffLine, extras: [FlatDiffRow])] = []
        let options = reviewOptions

        func appendExtra(_ row: FlatDiffRow) {
            guard case .row(let file, let r) = row else { return }
            rows.append(.view(id: row.id, group: false) { AnyView(rowView(r, file: file)) })
        }

        func flush() {
            defer { segment = [] }
            guard let file = segmentFile, !segment.isEmpty else { return }
            let extras = Dictionary(segment.map { ($0.line.id, $0.extras) }, uniquingKeysWith: { a, _ in a })
            for pair in DiffSplit.pair(segment.map(\.line)) {
                switch pair {
                case .full(let line):
                    let id = "r:" + file.id + ":l\(line.id)"
                    fileOf[id] = file.id
                    rows.append(.line(id: id, line: line, commentable: true, ext: ext))
                    extras[line.id]?.forEach(appendExtra)
                case .pair(let left, let right):
                    let id = "s:" + file.id + ":\(left?.id ?? -1):\(right?.id ?? -1)"
                    fileOf[id] = file.id
                    rows.append(.split(id: id, left: left, right: right, commentable: true, ext: ext))
                    if let left { extras[left.id]?.forEach(appendExtra) }
                    if let right, right.id != left?.id { extras[right.id]?.forEach(appendExtra) }
                }
            }
        }

        for row in flat {
            switch row {
            case .header(let file):
                flush()
                ext = file.syntaxExt
                rows.append(.view(id: row.id, group: true) { AnyView(FileHeader(model: model, file: file, showList: $showList, review: options, onBlame: blameAction)) })
            case .row(let file, let r):
                if case .line(let line) = r {
                    if split {
                        if segmentFile?.id != file.id {
                            flush()
                            segmentFile = file
                        }
                        segment.append((line, []))
                    } else {
                        fileOf[row.id] = file.id
                        rows.append(.line(id: row.id, line: line, commentable: true, ext: ext))
                    }
                } else if split, segmentFile?.id == file.id, !segment.isEmpty {
                    segment[segment.count - 1].extras.append(row)
                } else {
                    flush()
                    appendExtra(row)
                }
            }
        }
        flush()
        return (rows, fileOf)
    }

    @ViewBuilder
    private func rowView(_ row: DiffRow, file: DiffFile) -> some View {
        switch row {
        case .line(let line):
            DiffLineView(line: line) {
                guard let n = line.anchorLine else { return }
                model.composer = DiffAnchor(path: file.id, line: n, side: line.anchorSide)
            }
            .equatable()
        case .thread(let t):
            InlineThreadView(model: model, thread: t)
        case .pending(let p):
            PendingCommentView(model: model, comment: p)
        case .composer(let anchor):
            InlineComposer(model: model, anchor: anchor)
        case .note(let text):
            Text(text).font(.syCaption).foregroundStyle(Color.syMuted).padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

@Observable
final class FileFocus {
    var current: String?
}

final class DiffRowsCache {
    var key = ""
    var version = 0
    var rows: [DiffTableRow] = []
    var fileOf: [String: String] = [:]
}

private struct DiffRefreshHost<Content: View>: View {
    let model: PRDetailModel
    @ViewBuilder let content: Content

    var body: some View {
        content
            .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false) { await model.load(full: true) }
    }
}

private struct FileListPane: View {
    @Bindable var model: PRDetailModel
    let focus: FileFocus
    @Binding var filter: String
    let files: [DiffFile]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter files", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                Text("\(model.viewedPaths.intersection(model.files.map(\.id)).count)/\(model.files.count)")
                    .font(.syCaption.monospacedDigit()).foregroundStyle(Color.syMuted).help("Viewed")
            }
            .padding(8)
            List(files, selection: Binding(get: { focus.current ?? model.scrollTarget }, set: { p in if let p { model.revealFile(p) } })) { f in
                HStack(spacing: 6) {
                    Text(f.statusLetter)
                        .font(.syCaption2.weight(.bold).monospaced())
                        .foregroundStyle(statusColor(f.status))
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text((f.id as NSString).lastPathComponent).font(.syBody).lineLimit(1)
                        Text((f.id as NSString).deletingLastPathComponent).font(.syCaption2).foregroundStyle(Color.syMuted).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 2)
                    if model.threadCount(f.id) > 0 {
                        Image(systemName: "text.bubble").font(.syCaption2).foregroundStyle(Color.syMuted).accessibilityLabel("Has comments")
                    }
                    if model.viewedPaths.contains(f.id) {
                        Image(systemName: "checkmark.circle.fill").font(.syCaption).foregroundStyle(Color.ghGreen).accessibilityLabel("Viewed")
                    }
                }
                .rowAppear(f.id, model.fileRows)
                .tag(f.id)
            }
            .listStyle(.inset)
            .surface(.list)
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "added": return .ghGreen
        case "removed": return .ghRed
        case "renamed": return .ghPurple
        default: return .ghYellow
        }
    }
}

struct DiffReviewOptions {
    var wrap: Bool
    var split: Bool
    var splitAvailable: Bool
    var perform: (String) -> Void
}

struct FileHeader: View {
    @Bindable var model: PRDetailModel
    let file: DiffFile
    @Binding var showList: Bool
    var review: DiffReviewOptions?
    var onBlame: ((DiffFile) -> Void)?

    var body: some View {
        let collapsed = model.collapsed.contains(file.id)
        let viewed = model.viewedPaths.contains(file.id)
        HStack(spacing: 8) {
            Button {
                if collapsed { model.collapsed.remove(file.id) } else { model.collapsed.insert(file.id) }
            } label: {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down").frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand file" : "Collapse file")
            .accessibilityLabel(collapsed ? "Expand file" : "Collapse file")
            Group {
                if let prev = file.previousFilename {
                    Text("\(prev) → \(file.id)")
                } else {
                    Text(file.id)
                }
            }
            .font(.syCallout.monospaced().weight(.medium))
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
            DiffStat(additions: file.additions, deletions: file.deletions)
            Spacer()
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { _ in Task { await model.toggleViewed(file.id) } }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(review == nil ? "Mark file as viewed" : "Mark file as viewed (V)")
            Menu {
                Button("Copy path") { copyToPasteboard(file.id) }
                if file.status != "removed", let onBlame {
                    Button("Blame") { onBlame(file) }
                }
                Button(showList ? "Hide file list" : "Show file list") { showList.toggle() }
                Button("Collapse all") { model.collapsed = Set(model.files.map(\.id)) }
                Button("Expand all") { model.collapsed = [] }
                if let review {
                    Divider()
                    Button("Next file (N)") { review.perform("n") }
                    Button("Previous file (P)") { review.perform("p") }
                    Button("Next hunk (])") { review.perform("]") }
                    Button("Previous hunk ([)") { review.perform("[") }
                    Button(viewed ? "Mark as not viewed (V)" : "Mark as viewed (V)") { Task { await model.toggleViewed(file.id) } }
                    Divider()
                    Toggle("Wrap lines (W)", isOn: Binding(get: { review.wrap }, set: { _ in review.perform("w") }))
                    Toggle("Split view (S)", isOn: Binding(get: { review.split }, set: { _ in review.perform("s") }))
                        .disabled(!review.splitAvailable)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.isBrand ? AnyShapeStyle(Color.syRaised) : AnyShapeStyle(.bar))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.syLine).frame(height: 1) }
        .overlay(alignment: .top) { Rectangle().fill(Color.syLine).frame(height: 1) }
        .padding(.top, 8)
    }
}

struct DiffLineView: View, Equatable {
    let line: DiffLine
    var onComment: (() -> Void)?

    private static var font: Font { .sy(size: 12, design: .monospaced) }
    private static let addBG = Color.syAddBG
    private static let delBG = Color.syDelBG
    private static let hunkBG = Color(nsColor: .syHunkBG)

    static func == (a: DiffLineView, b: DiffLineView) -> Bool {
        a.line.id == b.line.id && a.line.text == b.line.text && a.line.kind == b.line.kind && (a.onComment == nil) == (b.onComment == nil)
    }

    var body: some View {
        if line.kind == .hunk {
            Text(line.text)
                .font(Self.font)
                .foregroundStyle(Color.syMuted)
                .padding(.leading, TextZoom.shared.size(104))
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.hunkBG)
        } else {
            HStack(alignment: .top, spacing: 0) {
                Text(gutterText)
                    .foregroundStyle(Color.syDim)
                    .frame(width: TextZoom.shared.size(108), alignment: .trailing)
                    .onTapGesture { if line.commentable { onComment?() } }
                Text(sign + line.text)
                    .foregroundStyle(line.kind == .meta ? .secondary : .primary)
                    .padding(.leading, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Self.font)
            .background(background)
        }
    }

    private var gutterText: String {
        let o = line.oldLine.map(String.init) ?? ""
        let n = line.newLine.map(String.init) ?? ""
        let pad = { (s: String) in String(repeating: " ", count: max(0, 5 - s.count)) + s }
        return pad(o) + " " + pad(n) + (line.commentable && onComment != nil ? " +" : "  ")
    }

    private var sign: String {
        switch line.kind {
        case .add: return "+"
        case .del: return "-"
        case .context: return " "
        default: return ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .add: return Self.addBG
        case .del: return Self.delBG
        default: return .clear
        }
    }
}

struct InlineThreadView: View {
    let model: PRDetailModel
    let thread: ReviewThread
    @State private var expanded: Bool?
    @State private var reply = ""
    @State private var replying = false

    var body: some View {
        let open = expanded ?? !thread.isResolved
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { expanded = !open } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 10)
                }
                .buttonStyle(.plain)
                .help(open ? "Collapse thread" : "Expand thread")
                .accessibilityLabel(open ? "Collapse thread" : "Expand thread")
                Image(systemName: "text.bubble")
                Text(plural(thread.comments.nodes.count, "comment", "comments")).font(.syCaption)
                if thread.isOutdated { Text("outdated").font(.syCaption2).foregroundStyle(Color.syMuted) }
                if thread.isResolved { Text("resolved").font(.syCaption2).foregroundStyle(Color.ghGreen) }
                Spacer()
                if thread.isResolved, thread.viewerCanUnresolve {
                    Button("Unresolve") { Task { await model.setResolved(thread.id, false) } }.controlSize(.small)
                } else if !thread.isResolved, thread.viewerCanResolve {
                    Button("Resolve") { Task { await model.setResolved(thread.id, true) } }.controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    ForEach(thread.comments.nodes) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Avatar(url: c.author?.avatarUrl, size: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(c.author?.login ?? "ghost").fontWeight(.semibold)
                                    Text("· \(Fmt.rel(c.createdAt))").foregroundStyle(Color.syMuted)
                                }
                                .font(.syCaption)
                                MarkdownText(text: c.body).font(.syCallout)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    if thread.viewerCanReply {
                        Divider()
                        if replying {
                            VStack(alignment: .trailing, spacing: 6) {
                                ComposerBox(text: $reply, placeholder: "Reply", minHeight: 50).frame(maxHeight: 120)
                                HStack {
                                    Button("Cancel") { replying = false; reply = "" }
                                    Button("Reply") {
                                        let body = reply
                                        Task { if await model.reply(thread.id, body: body) { reply = ""; replying = false } }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .keyboardShortcut(.return, modifiers: .command)
                                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                        } else {
                            Button("Reply…") { replying = true }
                                .buttonStyle(.borderless)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .font(.syCallout)
        .card(radius: 10)
        .padding(.horizontal, 12)
        .padding(.leading, 96)
        .padding(.vertical, 6)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

struct PendingCommentView: View {
    let model: PRDetailModel
    let comment: PendingComment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("pending").font(.syCaption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.ghYellow.opacity(0.25)))
            MarkdownText(text: comment.body).font(.syCallout)
            Spacer()
            Button {
                model.pending.removeAll { $0.id == comment.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete pending comment")
            .accessibilityLabel("Delete pending comment")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.ghYellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.ghYellow.opacity(0.4)))
        .padding(.horizontal, 12)
        .padding(.leading, 96)
        .padding(.vertical, 6)
        .frame(maxWidth: 900, alignment: .leading)
    }
}

struct InlineComposer: View {
    let model: PRDetailModel
    let anchor: DiffAnchor
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ComposerBox(text: $text, placeholder: "Comment on line \(anchor.line) (Markdown)", minHeight: 70)
                .frame(maxHeight: 160)
                .focused($focused)
            HStack {
                Button("Cancel") { model.composer = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add to review") { submit(immediately: false) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(empty)
                    .help("Save as pending and submit with the review")
                Button("Add single comment") { submit(immediately: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(empty || model.busy)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syAccent.opacity(0.5)))
        .padding(.horizontal, 12)
        .padding(.leading, 96)
        .padding(.vertical, 6)
        .frame(maxWidth: 900, alignment: .leading)
        .onAppear { focused = true }
    }

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func submit(immediately: Bool) {
        let body = text
        Task { _ = await model.addInline(anchor, body: body, immediately: immediately) }
    }
}
