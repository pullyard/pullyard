import SwiftUI

struct ProjectsListView: View {
    @Environment(AppModel.self) private var app
    @State private var projects: [ProjectSummary] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showClosed = false
    @State private var lastUpdated: Date?
    @State private var rows = RowAppearTracker.shared("projects")

    var body: some View {
        List(selection: Binding(get: { app.detailRoot }, set: { app.select($0) })) {
            if !app.hasProjectScope || (error?.contains("scope") ?? false) {
                ScopeHint()
            } else if let error, !projects.isEmpty {
                ListErrorNote(message: error) { await load() }
            }
            ForEach(projects.filter { showClosed || !$0.closed }) { p in
                HStack(alignment: .top, spacing: 9) {
                    IconTile(systemImage: "rectangle.split.3x1.fill", color: p.closed ? .sySlate : .syIndigo, size: 22)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(p.title).font(.syBody).fontWeight(.medium).foregroundStyle(Color.syText).lineLimit(1)
                            if p.closed { ChipView(text: "closed", color: .sySlate) }
                        }
                        if let d = p.shortDescription, !d.isEmpty { Text(d).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(2) }
                        HStack(spacing: 6) {
                            Text("\(p.owner?.login ?? "") · #\(p.number)").foregroundStyle(Color.syMuted)
                            Text("·").foregroundStyle(Color.syDim)
                            Text(plural(p.items.totalCount, "item", "items")).foregroundStyle(Color.syIndigo)
                            Spacer()
                            Text(Fmt.rel(p.updatedAt)).foregroundStyle(Color.syDim)
                        }
                        .font(.syCaption)
                    }
                }
                .padding(.vertical, 4)
                .rowAppear(p.id, rows)
                .tag(Route.project(p.ref))
                .contextMenu { Button("Open in Browser") { openInBrowser(p.url) } }
            }
        }
        .overlay {
            if loading && projects.isEmpty {
                PullYardLoader(size: 44)
            } else if app.hasProjectScope, let error, !error.contains("scope"), projects.isEmpty {
                ListErrorNote(message: error, centered: true) { await load() }
            } else if app.hasProjectScope, error == nil, !loading, !projects.contains(where: { showClosed || !$0.closed }) {
                ListEmptyNote(
                    title: projects.isEmpty ? "No projects" : "No open projects",
                    message: projects.isEmpty ? "Projects you can access show up here." : "Closed projects are hidden.",
                    actionTitle: projects.isEmpty ? nil : "Show closed",
                    action: { showClosed = true }
                )
            }
        }
        .liveRefresh(updated: lastUpdated, refreshing: loading, error: projects.isEmpty ? nil : error) { await load() }
        .columnTitle("Projects")
        .panelToolbar {
            ToolbarItem {
                Toggle(isOn: $showClosed) { Label("Closed", systemImage: "archivebox") }.help("Show closed")
            }
        }
        .task { await load(first: true) }
        .onChange(of: app.refreshTick) { Task { await load() } }
        .onLiveTick { await load() }
        .onChange(of: showClosed) { rows.ingest(projects.filter { showClosed || !$0.closed }.map(\.id), mode: .cascade) }
    }

    private func load(first: Bool = false) async {
        guard let api = app.api else { return }
        loading = true
        defer { loading = false }
        do {
            let fetched = try await api.projects()
            rows.ingest(fetched.filter { showClosed || !$0.closed }.map(\.id), mode: first ? .cascade : .refresh)
            projects = fetched
            lastUpdated = Date()
            error = nil
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }
}

struct ScopeHint: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconTile(systemImage: "key.fill", color: .syAmber, size: 22)
                Text("Token is missing Projects scopes").font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText)
            }
            Text("Run this in Terminal, then click “Refresh Token”:").font(.syCaption).foregroundStyle(Color.syMuted)
            Text("gh auth refresh -s read:project,project")
                .font(.syCaption.monospaced())
                .foregroundStyle(Color.syText)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(radius: 6, fill: .sySunken)
            HStack {
                Button("Copy Command") { copyToPasteboard("gh auth refresh -s read:project,project") }
                Button("Refresh Token from gh") {
                    busy = true
                    Task {
                        await app.refreshTokenFromGH()
                        busy = false
                        app.refresh()
                    }
                }
                .disabled(busy)
            }
            .controlSize(.small)
        }
        .padding(10)
        .card(radius: 10, fill: Color.syAmber.opacity(0.08))
        .padding(.vertical, 4)
    }
}

@Observable
@MainActor
final class ProjectBoardModel {
    let ref: ProjectRef
    let api: GitHubAPI
    var detail: ProjectDetail?
    var items: [ProjectItem] = []
    var fieldId: String?
    var loading = false
    var lastUpdated: Date?
    var error: String?
    var actionError: String?
    let rows: RowAppearTracker
    @ObservationIgnored private var loaded = false

    init(ref: ProjectRef, api: GitHubAPI) {
        self.ref = ref
        self.api = api
        rows = .shared("project|\(ref.id)")
    }

    var groupFields: [ProjectField] {
        (detail?.fields.nodes.compactMap(\.field) ?? []).filter { $0.options != nil }
    }

    var field: ProjectField? {
        groupFields.first { $0.id == fieldId }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let (d, items) = try await api.project(ref.id)
            detail = d
            if fieldId == nil || !groupFields.contains(where: { $0.id == fieldId }) {
                fieldId = (groupFields.first { $0.name.lowercased() == "status" } ?? groupFields.first)?.id
            }
            let visible = items.filter { !$0.isArchived }
            rows.ingest(cascadeOrder(visible), mode: loaded ? .refresh : .cascade)
            loaded = true
            self.items = visible
            lastUpdated = Date()
            error = nil
        } catch {
            if isCancellation(error) { return }
            self.error = error.localizedDescription
        }
    }

    private func cascadeOrder(_ items: [ProjectItem]) -> [String] {
        guard let fieldId else { return items.map(\.id) }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for item in items {
            let key = item.optionId(for: fieldId) ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item.id)
        }
        var out: [String] = []
        var depth = 0
        while out.count < items.count {
            for key in order where depth < groups[key]!.count { out.append(groups[key]![depth]) }
            depth += 1
        }
        return out
    }

    func move(_ itemId: String, to optionId: String?) async {
        guard let fieldId, let i = items.firstIndex(where: { $0.id == itemId }) else { return }
        guard items[i].optionId(for: fieldId) != optionId else { return }
        let backup = items[i]
        var nodes = items[i].fieldValues.nodes.filter { $0.field?.id != fieldId }
        if let optionId {
            nodes.append(ProjectFieldValue(typename: "ProjectV2ItemFieldSingleSelectValue", optionId: optionId, field: FieldRef(id: fieldId)))
        }
        items[i].fieldValues = Nodes(nodes: nodes)
        do {
            try await api.moveProjectItem(project: ref.id, item: itemId, field: fieldId, option: optionId)
        } catch {
            if let j = items.firstIndex(where: { $0.id == itemId }) { items[j] = backup }
            actionError = error.localizedDescription
        }
    }
}

struct ProjectBoardView: View {
    let project: ProjectRef
    @Environment(AppModel.self) private var app
    @State private var model: ProjectBoardModel?
    @State private var filter = ""

    var body: some View {
        Group {
            if let model {
                if model.detail != nil {
                    board(model)
                } else if let e = model.error {
                    ErrorStateView(message: e) { Task { await model.load() } }
                } else {
                    LoadingView()
                }
            } else {
                LoadingView()
            }
        }
        .detailTitle(project.title)
        .task(id: project) {
            guard let api = app.api else { return }
            let m = ProjectBoardModel(ref: project, api: api)
            model = m
            await m.load()
        }
        .onChange(of: app.refreshTick) { Task { await model?.load() } }
        .onLiveTick { await model?.load() }
    }

    private func board(_ model: ProjectBoardModel) -> some View {
        let columns = columnsFor(model)
        return VStack(spacing: 0) {
            BoardToolbar(model: model, filter: $filter, columns: columns)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView(.horizontal) {
                PYGlassGroup(spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(columns, id: \.id) { col in
                            ProjectColumn(model: model, column: col, items: col.items, options: model.field?.options ?? [])
                        }
                    }
                }
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .scrollIndicators(.automatic)
            RefreshFooter(updated: model.lastUpdated, refreshing: model.loading, error: model.error) {
                Task { await model.load() }
            }
        }
        .background { BoardBackdrop(colors: columns.map { projectColor($0.color) }) }
        .panelToolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openInBrowser(project.url) } label: { Label("Open in Browser", systemImage: "safari") }
                    .help("Open in browser")
            }
        }
        .alert("Error", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    struct Column {
        let id: String
        let optionId: String?
        let name: String
        let color: String
        let items: [ProjectItem]
    }

    private func columnsFor(_ model: ProjectBoardModel) -> [Column] {
        let items = model.items.filter { filter.isEmpty || ($0.content?.title ?? "").localizedCaseInsensitiveContains(filter) || ($0.content?.repository?.nameWithOwner ?? "").localizedCaseInsensitiveContains(filter) }
        guard let field = model.field, let fieldId = model.fieldId, let options = field.options else {
            return [Column(id: "all", optionId: nil, name: "All", color: "GRAY", items: items)]
        }
        var cols: [Column] = []
        let known = Set(options.map(\.id))
        let none = items.filter { $0.optionId(for: fieldId).map { !known.contains($0) } ?? true }
        if !none.isEmpty { cols.append(Column(id: "none", optionId: nil, name: "No \(field.name)", color: "GRAY", items: none)) }
        for o in options {
            cols.append(Column(id: o.id, optionId: o.id, name: o.name, color: o.color, items: items.filter { $0.optionId(for: fieldId) == o.id }))
        }
        return cols
    }
}

func projectColor(_ name: String) -> Color {
    switch name {
    case "BLUE": return .sySky
    case "GREEN": return .syGreen
    case "YELLOW": return .syAmber
    case "ORANGE": return .syCoral
    case "RED": return .syRed
    case "PINK": return .syCoral
    case "PURPLE": return .syViolet
    default: return .sySlate
    }
}


struct BoardBackdrop: View {
    let colors: [Color]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.syWindow
            if !reduceTransparency {
                GeometryReader { geo in
                    let palette = Array((colors.isEmpty ? [.syAccent, .syViolet] : colors).prefix(5))
                    ZStack {
                        ForEach(Array(palette.enumerated()), id: \.offset) { i, color in
                            let fraction = palette.count == 1 ? 0.5 : Double(i) / Double(palette.count - 1)
                            Ellipse()
                                .fill(color.opacity(scheme == .dark ? 0.22 : 0.14))
                                .frame(width: geo.size.width * 0.42, height: geo.size.height * 0.6)
                                .position(
                                    x: geo.size.width * (0.12 + fraction * 0.76),
                                    y: geo.size.height * (i.isMultiple(of: 2) ? 0.22 : 0.78)
                                )
                        }
                    }
                    .blur(radius: 110)
                    .drawingGroup()
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct BoardToolbar: View {
    @Bindable var model: ProjectBoardModel
    @Binding var filter: String
    let columns: [ProjectBoardView.Column]
    @FocusState private var searchFocused: Bool

    var body: some View {
        PYGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if model.groupFields.count > 1 {
                    Menu {
                        Picker("Group by", selection: $model.fieldId) {
                            ForEach(model.groupFields) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.split.3x1").foregroundStyle(Color.syMuted)
                            Text("Group by").foregroundStyle(Color.syMuted)
                            Text(model.field?.name ?? "—").fontWeight(.semibold).foregroundStyle(Color.syText)
                        }
                        .font(.syCaption)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .pyGlassCapsule(interactive: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? Color.syAccent : Color.syMuted)
                    TextField("Filter cards", text: $filter)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.syDim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                        .transition(.opacity)
                    }
                }
                .font(.syCaption)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 260)
                .pyGlassCapsule(tint: searchFocused ? Color.syAccent.opacity(0.12) : nil)
                .animation(Motion.fade, value: filter.isEmpty)
                .animation(Motion.fade, value: searchFocused)
                Spacer(minLength: 12)
                if columns.count > 1 {
                    BoardDistribution(columns: columns)
                }
                HStack(spacing: 5) {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.syIndigo)
                    Text(plural(columns.reduce(0) { $0 + $1.items.count }, "item", "items"))
                        .monospacedDigit()
                        .foregroundStyle(Color.syText)
                }
                .font(.syCaption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .pyGlassCapsule()
            }
        }
    }
}

struct BoardDistribution: View {
    let columns: [ProjectBoardView.Column]

    var body: some View {
        let total = max(1, columns.reduce(0) { $0 + $1.items.count })
        let filled = columns.filter { !$0.items.isEmpty }
        HStack(spacing: 2) {
            ForEach(filled, id: \.id) { col in
                Capsule()
                    .fill(projectColor(col.color).gradient)
                    .frame(width: max(6, 150 * CGFloat(col.items.count) / CGFloat(total)))
                    .help("\(col.name): \(col.items.count)")
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .pyGlassCapsule()
        .animation(Motion.smooth, value: filled.map(\.items.count))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(filled.map { "\($0.name) \($0.items.count)" }.joined(separator: ", "))
    }
}

struct ProjectColumn: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let model: ProjectBoardModel
    let column: ProjectBoardView.Column
    let items: [ProjectItem]
    let options: [ProjectOption]
    @State private var targeted = false

    private var tint: Color { projectColor(column.color) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: 10) {
                    if items.isEmpty {
                        emptySlot
                    }
                    ForEach(items) { item in
                        ProjectCard(item: item)
                            .rowAppear(item.id, model.rows, radius: 14)
                            .draggable(item.id) {
                                ProjectCard(item: item).frame(width: 276).opacity(0.95)
                            }
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
            .scrollIndicators(.hidden)
            .liveRefresh(updated: model.lastUpdated, refreshing: model.loading, footer: false) { await model.load() }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .top) {
            LinearGradient(colors: [tint.opacity(targeted ? 0.30 : (scheme == .dark ? 0.16 : 0.12)), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .clipShape(shape)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
        .pyGlass(in: shape, tint: tint.opacity(targeted ? 0.18 : 0.05), fallback: Color.sySunken.opacity(0.85))
        .overlay {
            shape.strokeBorder(targeted ? tint : Color.clear, lineWidth: 1.5)
        }
        .scaleEffect(targeted && !Motion.reduced ? 1.01 : 1)
        .animation(Motion.snappy, value: targeted)
        .dropDestination(for: String.self) { ids, _ in
            guard model.fieldId != nil else { return false }
            for id in ids { Task { await model.move(id, to: column.optionId) } }
            return true
        } isTargeted: { targeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .shadow(color: tint.opacity(0.7), radius: 4)
            Text(column.name)
                .font(.syBody.weight(.semibold))
                .foregroundStyle(Color.syText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(items.count)")
                .font(.syCaption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.16)))
                .contentTransition(.numericText())
                .animation(Motion.snappy, value: items.count)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    private var emptySlot: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "tray")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(targeted ? tint : Color.syDim)
            Text(targeted ? "Drop to move here" : "Nothing here yet")
                .font(.syCaption)
                .foregroundStyle(targeted ? tint : Color.syDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((targeted ? tint : Color.syLineStrong), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    @ViewBuilder
    private func menu(for item: ProjectItem) -> some View {
        Menu("Move to") {
            ForEach(options) { o in
                Button(o.name) { Task { await model.move(item.id, to: o.id) } }
            }
            Divider()
            Button("No Status") { Task { await model.move(item.id, to: nil) } }
        }
        if let url = item.content?.url {
            Button("Open in Browser") { openInBrowser(url) }
            Button("Copy Link") { copyToPasteboard(url) }
            if let ref = ShortLink.ref(url: url) {
                Button("Copy Short Link") { app.copyShortLink(ref) }
            }
        }
    }
}

struct ProjectCard: View {
    let item: ProjectItem
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        let c = item.content
        let state = c?.visualState
        let accent = state?.color ?? Color.syDim
        let assignees = c?.assignees?.nodes ?? []
        let content = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: state?.icon ?? "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(accent.opacity(0.14)))
                    .accessibilityLabel(state?.title ?? "Draft")
                Text(c?.repository?.nameWithOwner ?? "Draft")
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let n = c?.number {
                    Text("#\(n)")
                        .font(.syCaption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.syDim)
                }
                Spacer(minLength: 0)
            }
            Text(c?.title ?? "—")
                .font(.syCallout.weight(.medium))
                .foregroundStyle(Color.syText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !assignees.isEmpty || state != nil {
                HStack(spacing: 6) {
                    if let state {
                        Text(state.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: -6) {
                        ForEach(assignees.prefix(4), id: \.login) { a in
                            Avatar(url: a.avatarUrl, size: 20)
                                .overlay(Circle().strokeBorder(Color.syRaised, lineWidth: 1.5))
                                .help(a.login)
                        }
                        if assignees.count > 4 {
                            Text("+\(assignees.count - 4)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.syMuted)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.sySunken))
                                .overlay(Circle().strokeBorder(Color.syRaised, lineWidth: 1.5))
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.syRaised.opacity(GlassSupport.isAvailable ? (scheme == .dark ? 0.78 : 0.86) : 1))
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(scheme == .dark ? 0.14 : 0.7), Color.syLine],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .overlay {
            if hovering { shape.strokeBorder(accent.opacity(0.45), lineWidth: 1) }
        }
        .shadow(color: .black.opacity(hovering ? (scheme == .dark ? 0.38 : 0.12) : (scheme == .dark ? 0.22 : 0.05)), radius: hovering ? 12 : 4, y: hovering ? 6 : 2)
        .offset(y: hovering && !Motion.reduced ? -2 : 0)
        .contentShape(shape)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }

        if let route = c?.route {
            NavigationLink(value: route) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
