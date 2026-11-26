import SwiftUI

struct ProjectIssuesSections: View {
    let repo: String
    let state: String
    @EnvironmentObject private var model: AppModel
    @State private var issues: [GHIssue] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if issues.isEmpty {
                Section {
                    Group {
                        if let error {
                            ErrorStateView(title: "Couldn't load issues", message: error) { Task { await reload() } }
                        } else if loading || hasMore {
                            PullYardLoader(title: "Loading issues…", size: 64)
                        } else {
                            PYEmptyState(title: "No issues", message: "\(repo) has no \(state == "all" ? "" : state + " ")issues.")
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(issues, id: \.number) { issue in
                        NavigationLink(value: Route.issue(PRKey(repo: repo, number: issue.number))) { IssueRow(issue: issue) }
                            .pyRow()
                            .onAppear { if issue.number == issues.last?.number { Task { await loadMore() } } }
                    }
                    if hasMore {
                        HStack { Spacer(); PullYardLoader(size: 28); Spacer() }.pyRow()
                    }
                }
            }
        }
        .task(id: state) { await reload() }
    }

    private func reload() async {
        issues = []; page = 1; hasMore = true; error = nil
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let batch = try await model.issues(repo: repo, state: state, page: page)
            let known = Set(issues.map(\.number))
            issues += batch.filter { !known.contains($0.number) }
            hasMore = !batch.isEmpty
            page += 1
        } catch {
            if issues.isEmpty { self.error = error.localizedDescription }
            hasMore = false
        }
    }
}

private struct IssueRow: View {
    let issue: GHIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: issue.isOpen ? "smallcircle.filled.circle" : "checkmark.circle.fill")
                    .foregroundStyle(issue.isOpen ? MobileTheme.green : MobileTheme.violet)
                Text("#\(issue.number)").mobileFont(size: 12, weight: .semibold, design: .monospaced).foregroundStyle(MobileTheme.muted)
                Spacer()
                RelativeTime(date: issue.updatedAt).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
            }
            Text(issue.title).mobileFont(size: 16, weight: .semibold).foregroundStyle(MobileTheme.ink).lineLimit(2)
            HStack(spacing: 7) {
                if let author = issue.user?.login {
                    AvatarView(url: issue.user?.avatarUrl, size: 18, fallback: author)
                    Text(author).mobileFont(size: 13).foregroundStyle(MobileTheme.muted)
                }
                if let labels = issue.labels { ForEach(labels.prefix(2), id: \.name) { LabelChip(label: $0) } }
                Spacer()
                if let comments = issue.comments, comments > 0 {
                    Label("\(comments)", systemImage: "text.bubble").labelStyle(.titleAndIcon).mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct CreateIssueView: View {
    let repo: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var title = ""
    @State private var bodyText = ""
    @State private var creating = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var canCreate: Bool { !creating && !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill").mobileFont(size: 14).foregroundStyle(MobileTheme.red)
                }
                Label(repo, systemImage: "folder").mobileFont(size: 13, weight: .medium).foregroundStyle(MobileTheme.muted)
                TextField("Title", text: $title, axis: .vertical)
                    .focused($focused)
                    .mobileFont(size: 18, weight: .semibold)
                    .padding(14)
                    .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MobileTheme.line))
                TemplatesBar { template in bodyText += (bodyText.isEmpty || bodyText.hasSuffix("\n") ? "" : "\n") + template.body }
                TextEditor(text: $bodyText)
                    .mobileFont(size: 15)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 220)
                    .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(MobileTheme.line))
                    .overlay(alignment: .topLeading) {
                        if bodyText.isEmpty { Text("Description (Markdown)").mobileFont(size: 15).foregroundStyle(MobileTheme.dim).padding(16).allowsHitTesting(false) }
                    }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(BrandBackdrop())
        .safeAreaInset(edge: .bottom) {
            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if creating { PullYardLoader(size: 30, style: .monochrome(.white)) } else { Image(systemName: "smallcircle.filled.circle") }
                    Text(creating ? "Creating…" : "Create issue")
                }
                .mobileFont(size: 17, weight: .semibold).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Capsule())
                .pyGlass(in: Capsule(), tint: MobileTheme.greenFill, interactive: true, fallback: MobileTheme.greenFill)
            }
            .buttonStyle(.pyPlain)
            .disabled(!canCreate)
            .opacity(canCreate ? 1 : 0.55)
            .padding(.horizontal, 18).padding(.bottom, 10)
        }
        .navigationTitle("New issue")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear { focused = true }
    }

    private func create() async {
        creating = true; errorMessage = nil
        defer { creating = false }
        do {
            let key = try await model.createIssue(repo: repo, title: title.trimmingCharacters(in: .whitespaces), body: bodyText)
            feedback.success("Opened issue #\(key.number)")
            router.replaceTop(with: .issue(key), in: model.selectedTab)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RepoBrowserView: View {
    let repo: String
    let ref: String?
    let path: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter
    @AppStorage("mobile.diff.wrap") private var wrap = true
    @State private var content: RepoContent?
    @State private var error: String?
    @State private var branches: [String] = []

    private var title: String { path.isEmpty ? String(repo.split(separator: "/").last ?? Substring(repo)) : String(path.split(separator: "/").last ?? Substring(path)) }

    var body: some View {
        Group {
            switch content {
            case let .directory(entries):
                List {
                    Section {
                        ForEach(entries) { entry in
                            NavigationLink(value: Route.browse(repo: repo, ref: ref, path: entry.path)) {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                        .foregroundStyle(entry.isDirectory ? MobileTheme.accent : MobileTheme.muted)
                                        .frame(width: 22)
                                    Text(entry.name).mobileFont(size: 15, weight: entry.isDirectory ? .semibold : .regular).foregroundStyle(MobileTheme.ink).lineLimit(1)
                                    Spacer()
                                    if let size = entry.size, !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).mobileFont(size: 12).foregroundStyle(MobileTheme.dim)
                                    }
                                }
                            }
                            .pyRow()
                        }
                    } header: {
                        Text(path.isEmpty ? repo : path).textCase(nil).lineLimit(1).truncationMode(.head)
                    }
                }
                .pyListStyle()
            case let .file(file):
                fileView(file)
            case nil:
                if let error {
                    ErrorStateView(title: "Couldn't open", message: error) { Task { await load() } }
                } else {
                    PullYardLoader(title: "Loading…", size: 64).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(BrandBackdrop())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !branches.isEmpty {
                        Section("Branch") {
                            ForEach(branches.prefix(40), id: \.self) { branch in
                                Button { router.replaceTop(with: .browse(repo: repo, ref: branch, path: path), in: model.selectedTab) } label: {
                                    if branch == ref { Label(branch, systemImage: "checkmark") } else { Text(branch) }
                                }
                            }
                        }
                    }
                    Toggle(isOn: $wrap) { Label("Wrap lines", systemImage: "text.word.spacing") }
                    Link(destination: URL(string: "https://github.com/\(repo)/tree/\(ref ?? "HEAD")/\(path)")!) { Label("Open on GitHub", systemImage: "safari") }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(ref.map { String($0.prefix(14)) } ?? "default").mobileFont(size: 13, weight: .semibold)
                    }
                }
                .task { if branches.isEmpty { branches = (try? await model.branches(repo: repo)) ?? [] } }
            }
        }
        .task { await load() }
    }

    @ViewBuilder private func fileView(_ file: RepoFile) -> some View {
        if file.isImage, let url = file.downloadUrl {
            ScrollView { AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { PullYardLoader(size: 48) }.padding() }
        } else if let text = file.text {
            let lines = text.components(separatedBy: "\n")
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1)").foregroundStyle(MobileTheme.dim).frame(width: 40, alignment: .trailing)
                            Text(line.isEmpty ? " " : line)
                                .foregroundStyle(MobileTheme.ink)
                                .lineLimit(wrap ? nil : 1)
                                .fixedSize(horizontal: !wrap, vertical: false)
                                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        }
                        .mobileFont(size: 12, design: .monospaced)
                        .padding(.vertical, 1)
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
        } else {
            PYEmptyState(title: "Can't preview this file", message: "It's binary or larger than GitHub's 1 MB preview limit.") {
                if let url = file.htmlUrl { Link("Open on GitHub", destination: url).pyGlassButton(prominent: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "kt", "java", "ts", "tsx", "js", "py", "rb", "go", "rs", "dart", "c", "cpp", "h", "m", "cs": return "chevron.left.forwardslash.chevron.right"
        case "md", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml", "plist", "xml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        default: return "doc"
        }
    }

    private func load() async {
        error = nil
        do { content = try await model.contents(repo: repo, path: path, ref: ref) }
        catch { self.error = error.localizedDescription }
    }
}
