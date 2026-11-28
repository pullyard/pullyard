import SwiftUI

@MainActor
final class FilesStore: ObservableObject {
    static let shared = FilesStore()
    @Published private(set) var files: [PRKey: [PRFile]] = [:]
    @Published private(set) var comments: [PRKey: [PRComment]] = [:]
    @Published private(set) var states: [PRKey: LoadState] = [:]

    func load(_ key: PRKey, model: AppModel, force: Bool = false) async {
        if !force, files[key] != nil { return }
        if files[key] == nil { states[key] = .loading }
        let filesTask = Task { try await model.files(key) }
        let commentsTask = Task { try await model.reviewComments(key) }
        do {
            let value = try await filesTask.value
            files[key] = value
            comments[key] = (try? await commentsTask.value) ?? comments[key] ?? []
            states[key] = .loaded(.now)
            if let viewed = try? await model.viewedStates(key) { model.syncViewed(viewed, files: value, for: key) }
        } catch {
            if !error.isCancellation { states[key] = .failed(error.localizedDescription) }
        }
    }

    func state(_ key: PRKey) -> LoadState { states[key] ?? .idle }
}

struct FilesView: View {
    let key: PRKey
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var store = FilesStore.shared
    @State private var query = ""

    private var files: [PRFile] { store.files[key] ?? [] }
    private var filtered: [PRFile] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? files : files.filter { $0.filename.localizedCaseInsensitiveContains(trimmed) }
    }
    private var viewedCount: Int { files.filter { model.isViewed($0, for: key) }.count }

    var body: some View {
        List {
            if !files.isEmpty {
                Section {
                    HStack(spacing: 14) {
                        Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(MobileTheme.green)
                        Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(MobileTheme.red)
                        Text("\(files.count) files").foregroundStyle(MobileTheme.muted)
                        Spacer()
                        Label("\(viewedCount)/\(files.count) viewed", systemImage: "eye").foregroundStyle(MobileTheme.muted)
                    }
                    .mobileFont(size: 13, weight: .semibold)
                    ProgressView(value: Double(viewedCount), total: Double(max(files.count, 1))).tint(MobileTheme.green)
                }
                .pyRow()
            }
            if files.isEmpty {
                Section {
                    Group {
                        switch store.state(key) {
                        case let .failed(message):
                            ErrorStateView(title: "Couldn't load files", message: message) { Task { await store.load(key, model: model, force: true) } }
                        case .loaded:
                            PYEmptyState(title: "No changed files", message: "This pull request has no file changes.")
                        default:
                            PullYardLoader(title: "Loading changed files…", size: 72)
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filtered) { file in
                        NavigationLink(value: Route.fileDiff(key, file.filename)) {
                            FileRow(file: file, viewed: model.isViewed(file, for: key), comments: (store.comments[key] ?? []).filter { $0.path == file.filename }.count)
                        }
                        .pyRow()
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            let viewed = model.isViewed(file, for: key)
                            Button { model.setViewed(file, viewed: !viewed, for: key) } label: { Label(viewed ? "Unview" : "Viewed", systemImage: viewed ? "eye.slash" : "eye") }
                                .tint(MobileTheme.greenFill)
                        }
                    }
                }
            }
        }
        .pyListStyle()
        .searchable(text: $query, prompt: "Filter by path")
        .refreshable { await store.load(key, model: model, force: true) }
        .navigationTitle("Files changed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await store.load(key, model: model) }
        .feedbackChrome()
    }
}

private struct FileRow: View {
    let file: PRFile
    let viewed: Bool
    let comments: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file.statusSymbol).foregroundStyle(color).mobileFont(size: 17)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).mobileFont(size: 15, weight: .semibold).foregroundStyle(viewed ? MobileTheme.muted : MobileTheme.ink).lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory).mobileFont(size: 12, design: .monospaced).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 6)
            if comments > 0 { Label("\(comments)", systemImage: "text.bubble").labelStyle(.titleAndIcon).mobileFont(size: 12).foregroundStyle(MobileTheme.accent) }
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(file.additions)").foregroundStyle(MobileTheme.green)
                Text("−\(file.deletions)").foregroundStyle(MobileTheme.red)
            }
            .mobileFont(size: 12, weight: .semibold, design: .rounded)
            .monospacedDigit()
            if viewed { Image(systemName: "checkmark.circle.fill").foregroundStyle(MobileTheme.green) }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(viewed ? "Viewed" : "")
    }

    private var color: Color {
        switch file.status { case "added": MobileTheme.green; case "removed": MobileTheme.red; case "renamed": MobileTheme.violet; default: MobileTheme.amber }
    }
}

struct FileDiffView: View {
    let key: PRKey
    let path: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var store = FilesStore.shared
    @AppStorage("mobile.diff.wrap") private var wrap = true
    @State private var replyTo: PRComment?
    @State private var lineComposer: ComposerRequest?

    private var file: PRFile? { store.files[key]?.first { $0.filename == path } }
    private var nextFile: PRFile? {
        guard let files = store.files[key], let index = files.firstIndex(where: { $0.filename == path }), index + 1 < files.count else { return nil }
        return files[index + 1]
    }
    private var threads: [Int: [PRComment]] {
        let fileComments = (store.comments[key] ?? []).filter { $0.path == path }
        let grouped = Dictionary(grouping: fileComments, by: \.threadRootId)
        var byLine: [Int: [PRComment]] = [:]
        for (_, items) in grouped {
            let sorted = items.sorted { $0.createdAt < $1.createdAt }
            guard let root = sorted.first, let line = root.line ?? root.originalLine else { continue }
            byLine[line, default: []] += sorted
        }
        return byLine
    }

    var body: some View {
        Group {
            if let file {
                content(file)
            } else if case let .failed(message) = store.state(key) {
                ErrorStateView(title: "Couldn't load the diff", message: message) { Task { await store.load(key, model: model, force: true) } }
            } else {
                PullYardLoader(title: "Loading diff…", size: 72).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(MobileTheme.canvas)
        .navigationTitle(String(path.split(separator: "/").last ?? Substring(path)))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let file {
                    Button { model.setViewed(file, viewed: !model.isViewed(file, for: key), for: key) } label: {
                        Image(systemName: model.isViewed(file, for: key) ? "eye.fill" : "eye")
                    }
                    .accessibilityLabel(model.isViewed(file, for: key) ? "Mark as not viewed" : "Mark as viewed")
                    Menu {
                        Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
                        if let url = file.blobUrl { Link(destination: url) { Label("Open on GitHub", systemImage: "safari") } }
                        Button { UIPasteboard.general.string = file.filename } label: { Label("Copy path", systemImage: "doc.on.doc") }
                        if file.status != "removed" {
                            NavigationLink(value: Route.browse(repo: key.repo, ref: model.cachedDetail(key)?.insight?.headSHA ?? model.cachedDetail(key)?.pull.head.sha, path: file.filename)) {
                                Label("View full file", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task { await store.load(key, model: model) }
        .sheet(item: $lineComposer) { request in
            ComposerSheet(request: request, send: { body in try await addLineComment(request, body: body, pending: true) }, alternate: { body in try await addLineComment(request, body: body, pending: false) })
        }
        .sheet(item: $replyTo) { comment in
            ComposerSheet(request: ComposerRequest(title: "Reply to thread", mode: .reply(comment.threadRootId), draft: DraftKey(pull: key, kind: .reply(comment.threadRootId)), context: comment)) { body in
                try await model.reply(key, commentID: comment.threadRootId, body: body)
                feedback.success("Reply posted")
                await store.load(key, model: model, force: true)
            }
        }
        .feedbackChrome()
    }

    @ViewBuilder private func content(_ file: PRFile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.filename).mobileFont(size: 13, weight: .medium, design: .monospaced).foregroundStyle(MobileTheme.muted).textSelection(.enabled)
                    if let previous = file.previousFilename { Label("Renamed from \(previous)", systemImage: "arrow.right").mobileFont(size: 12).foregroundStyle(MobileTheme.violet) }
                    HStack(spacing: 10) {
                        Text("+\(file.additions)").foregroundStyle(MobileTheme.green)
                        Text("−\(file.deletions)").foregroundStyle(MobileTheme.red)
                        Spacer()
                        Label("Long-press a line to comment", systemImage: "hand.tap").foregroundStyle(MobileTheme.muted).mobileFont(size: 12)
                    }
                    .mobileFont(size: 13, weight: .semibold)
                }
                .padding(16)
                if let patch = file.patch {
                    let lines = DiffLine.parse(patch)
                    let anchored = threads
                    if wrap {
                        diffLines(lines, anchored: anchored)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) { Group { diffLines(lines, anchored: anchored).fixedSize(horizontal: true, vertical: false) }.background(HorizontalOnly()) }
                    }
                } else {
                    PYEmptyState(title: "Diff not shown", message: "This file is binary or too large to display here.") {
                        if let url = file.blobUrl { Link("Open on GitHub", destination: url).pyGlassButton(prominent: true) }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if let nextFile {
                    Button { router.replaceTop(with: .fileDiff(key, nextFile.filename), in: model.selectedTab) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next file").mobileFont(size: 12, weight: .semibold).foregroundStyle(MobileTheme.muted)
                                Text(nextFile.name).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(MobileTheme.accent)
                        }
                        .padding(16)
                        .pyGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: true, fallback: MobileTheme.card)
                    }
                    .buttonStyle(.pyPlain)
                    .padding(16)
                    .simultaneousGesture(TapGesture().onEnded { model.setViewed(file, viewed: true, for: key) })
                }
            }
        }
    }

    private func diffLines(_ lines: [DiffLine], anchored: [Int: [PRComment]]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                DiffLineRow(line: line, wrap: wrap)
                    .contextMenu {
                        if line.kind != .hunk, let target = target(for: line) {
                            Button { openLineComposer(line: target.line, side: target.side) } label: { Label("Comment on line \(target.line)", systemImage: "text.bubble") }
                            Button { UIPasteboard.general.string = line.text } label: { Label("Copy line", systemImage: "doc.on.doc") }
                        }
                    }
                if let newLine = line.newLine, line.kind != .delete, let comments = anchored[newLine] {
                    InlineThread(comments: comments) { replyTo = comments.last }
                }
            }
        }
    }
}

extension FileDiffView {
    fileprivate func target(for line: DiffLine) -> (line: Int, side: String)? {
        if line.kind == .delete, let old = line.oldLine { return (old, "LEFT") }
        if let new = line.newLine { return (new, "RIGHT") }
        return nil
    }

    fileprivate func openLineComposer(line: Int, side: String) {
        lineComposer = ComposerRequest(title: "Line \(line) · \(path.split(separator: "/").last ?? "")", mode: .lineComment(path: path, line: line, side: side), draft: DraftKey(pull: key, kind: .reply(-line)), alternateTitle: "Comment now")
    }

    fileprivate func addLineComment(_ request: ComposerRequest, body: String, pending: Bool) async throws {
        guard case let .lineComment(path, line, side) = request.mode else { return }
        let detail = model.cachedDetail(key)
        if pending {
            guard let pullID = detail?.insight?.nodeID else { throw GitHubError.message("Open the pull request once so PullYard can start a review, then try again.") }
            let pendingID = detail?.reviews.first(where: \.isPending)?.nodeId
            try await model.addPendingLineComment(pullID: pullID, reviewNodeID: pendingID, path: path, line: line, side: side, body: body)
            feedback.info("Added to your pending review", key: "pending-\(key.id)", actionTitle: "Finish review") { router.open(.finishReview(key), in: model.selectedTab) }
        } else {
            guard let sha = detail?.insight?.headSHA ?? detail?.pull.head.sha, !sha.isEmpty else { throw GitHubError.message("Open the pull request once, then try again.") }
            try await model.addSingleLineComment(key, commitID: sha, path: path, line: line, side: side, body: body)
            feedback.success("Comment posted")
        }
        await store.load(key, model: model, force: true)
    }
}

struct DiffLineRow: View {
    let line: DiffLine
    let wrap: Bool

    var body: some View {
        if line.kind == .hunk {
            Text(line.text)
                .mobileFont(size: 12, design: .monospaced)
                .foregroundStyle(MobileTheme.hunkText)
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MobileTheme.accent.opacity(0.08))
        } else {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                Text(line.newLine.map(String.init) ?? "").frame(width: 34, alignment: .trailing)
                Text(marker).frame(width: 18)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(textColor)
                    .lineLimit(wrap ? nil : 1)
                    .fixedSize(horizontal: !wrap, vertical: false)
                    .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    .textSelection(.enabled)
            }
            .mobileFont(size: 12, design: .monospaced)
            .foregroundStyle(MobileTheme.dim)
            .padding(.vertical, 1.5)
            .padding(.trailing, 8)
            .background(background)
        }
    }

    private var marker: String { line.kind == .add ? "+" : line.kind == .delete ? "−" : "" }
    private var textColor: Color { line.kind == .add ? MobileTheme.addText : line.kind == .delete ? MobileTheme.delText : MobileTheme.ink }
    private var background: Color { line.kind == .add ? MobileTheme.addBG : line.kind == .delete ? MobileTheme.delBG : .clear }
}

private struct InlineThread: View {
    let comments: [PRComment]
    let reply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        AvatarView(url: comment.user?.avatarUrl, size: 20, fallback: comment.user?.login)
                        Text(comment.user?.login ?? "Contributor").mobileFont(size: 13, weight: .semibold)
                        Spacer()
                        RelativeTime(date: comment.createdAt).mobileFont(size: 11).foregroundStyle(MobileTheme.muted)
                    }
                    MarkdownView(markdown: comment.body)
                }
            }
            Button(action: reply) { Label("Reply", systemImage: "arrowshape.turn.up.left").mobileFont(size: 13, weight: .semibold) }
                .foregroundStyle(MobileTheme.accent)
        }
        .pyCard(padding: 12)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
