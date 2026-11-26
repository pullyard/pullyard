import SwiftUI

struct CreatePullView: View {
    let repo: String
    let initialHead: String?
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var feedback: FeedbackCenter
    @EnvironmentObject private var router: AppRouter
    @State private var branches: [String] = []
    @State private var base = ""
    @State private var head = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var draft = false
    @State private var comparison: BranchComparison?
    @State private var comparing = false
    @State private var loadError: String?
    @State private var creating = false
    @State private var errorMessage: String?
    @State private var titleEdited = false
    @State private var bodyEdited = false

    private var canCreate: Bool {
        !creating && !base.isEmpty && !head.isEmpty && base != head && !title.trimmingCharacters(in: .whitespaces).isEmpty && (comparison?.aheadBy ?? 1) > 0
    }

    var body: some View {
        Form {
            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.circle.fill").foregroundStyle(MobileTheme.red) }
            }
            Section {
                LabeledContent("Repository", value: repo)
                if branches.isEmpty {
                    HStack { Text("Branches"); Spacer(); if loadError == nil { PullYardLoader(size: 26) } else { Text("Unavailable").foregroundStyle(MobileTheme.muted) } }
                } else {
                    Picker("Merge into", selection: $base) { ForEach(branches, id: \.self) { Text($0).tag($0) } }
                    Picker("From", selection: $head) { ForEach(branches, id: \.self) { Text($0).tag($0) } }
                }
            } header: {
                Text("Branches")
            } footer: {
                compareFooter
            }
            .pyRow()

            if let comparison, !comparison.messages.isEmpty {
                Section("Commits · \(comparison.aheadBy)") {
                    ForEach(Array(comparison.messages.suffix(6).enumerated()), id: \.offset) { _, message in
                        Label(String(message.split(separator: "\n").first ?? ""), systemImage: "smallcircle.filled.circle")
                            .mobileFont(size: 14).lineLimit(2)
                    }
                }
                .pyRow()
            }

            Section("Pull request") {
                TextField("Title", text: $title, axis: .vertical)
                    .mobileFont(size: 16, weight: .semibold)
                    .onChange(of: title) { _, _ in titleEdited = true }
                ZStack(alignment: .topLeading) {
                    if bodyText.isEmpty { Text("Description (Markdown)").foregroundStyle(MobileTheme.dim).padding(.top, 8).allowsHitTesting(false) }
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 140)
                        .scrollContentBackground(.hidden)
                        .onChange(of: bodyText) { _, _ in bodyEdited = true }
                }
                .mobileFont(size: 15)
                Toggle(isOn: $draft) { Label("Create as draft", systemImage: "circle.dashed") }
            }
            .pyRow()
        }
        .scrollContentBackground(.hidden)
        .background(BrandBackdrop())
        .safeAreaInset(edge: .bottom) {
            Button { Task { await create() } } label: {
                HStack(spacing: 8) {
                    if creating { PullYardLoader(size: 30, style: .monochrome(.white)) } else { Image(systemName: "arrow.triangle.pull") }
                    Text(creating ? "Opening…" : draft ? "Create draft pull request" : "Create pull request")
                }
                .mobileFont(size: 17, weight: .semibold).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Capsule())
                .pyGlass(in: Capsule(), tint: draft ? MobileTheme.slate : MobileTheme.greenFill, interactive: true, fallback: draft ? MobileTheme.slate : MobileTheme.greenFill)
            }
            .buttonStyle(.pyPlain)
            .disabled(!canCreate)
            .opacity(canCreate ? 1 : 0.55)
            .padding(.horizontal, 18).padding(.bottom, 10)
        }
        .navigationTitle("New pull request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task { await load() }
        .onChange(of: base) { _, _ in Task { await compare() } }
        .onChange(of: head) { _, _ in Task { await compare() } }
        .feedbackChrome()
    }

    @ViewBuilder private var compareFooter: some View {
        if comparing {
            Text("Comparing branches…")
        } else if let comparison {
            if base == head {
                Text("Choose two different branches.")
            } else if comparison.aheadBy == 0 {
                Text("\(head) has no new commits compared to \(base).").foregroundStyle(MobileTheme.amberInk)
            } else {
                Text("\(comparison.aheadBy) commit\(comparison.aheadBy == 1 ? "" : "s") · \(comparison.files) file\(comparison.files == 1 ? "" : "s") changed\(comparison.behindBy > 0 ? " · \(comparison.behindBy) behind \(base)" : "")")
            }
        } else if let loadError {
            Text(loadError)
        }
    }

    private func load() async {
        guard branches.isEmpty else { return }
        do {
            let defaultBranch = try await model.defaultBranch(repo: repo)
            let list = try await model.branches(repo: repo)
            branches = Array(Set(list + [defaultBranch] + (initialHead.map { [$0] } ?? []))).sorted { lhs, rhs in
                if lhs == defaultBranch { return true }
                if rhs == defaultBranch { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            base = defaultBranch
            head = initialHead ?? branches.first { $0 != defaultBranch } ?? defaultBranch
            await compare()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func compare() async {
        guard !base.isEmpty, !head.isEmpty, base != head else { comparison = nil; return }
        comparing = true
        defer { comparing = false }
        do {
            let value = try await model.compare(repo: repo, base: base, head: head)
            comparison = value
            if !titleEdited || title.isEmpty {
                let firstLine = value.messages.count == 1 ? value.messages[0].split(separator: "\n").first.map(String.init) : nil
                title = firstLine ?? humanized(head)
                titleEdited = false
            }
            if !bodyEdited || bodyText.isEmpty, value.messages.count > 1 {
                bodyText = value.messages.map { "- " + ($0.split(separator: "\n").first.map(String.init) ?? "") }.joined(separator: "\n")
                bodyEdited = false
            }
        } catch {
            comparison = nil
            errorMessage = error.localizedDescription
        }
    }

    private func humanized(_ branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    private func create() async {
        guard canCreate else { return }
        creating = true; errorMessage = nil
        defer { creating = false }
        do {
            let key = try await model.createPull(repo: repo, title: title.trimmingCharacters(in: .whitespaces), head: head, base: base, body: bodyText, draft: draft)
            feedback.success("Opened \(repo.split(separator: "/").last ?? "")#\(key.number)")
            router.replaceTop(with: .pull(key), in: model.selectedTab)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PushedBranchesCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let branches = model.suggestedBranches
        if !branches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Pushed, no pull request yet", systemImage: "arrow.up.circle.fill")
                    .mobileFont(size: 15, weight: .semibold)
                    .foregroundStyle(MobileTheme.amberInk)
                ForEach(branches) { branch in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(MobileTheme.accent).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(branch.branch).mobileFont(size: 14, weight: .semibold, design: .monospaced).foregroundStyle(MobileTheme.ink).lineLimit(1).truncationMode(.middle)
                            (Text("\(branch.repo) · ") + Text(branch.pushedAt, style: .relative) + Text(" ago"))
                                .font(.caption).foregroundStyle(MobileTheme.muted).lineLimit(1)
                            if let headline = branch.headline {
                                Text(headline).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        NavigationLink(value: Route.newPull(repo: branch.repo, head: branch.branch)) {
                            Text("Create PR")
                                .mobileFont(size: 13, weight: .semibold).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .contentShape(Capsule())
                                .pyGlassCapsule(tint: MobileTheme.greenFill, interactive: true, fallback: MobileTheme.greenFill)
                        }
                        .buttonStyle(.pyPlain)
                        Button { withAnimation(.snappy) { model.dismissBranch(branch) } } label: {
                            Image(systemName: "xmark").mobileFont(size: 12, weight: .bold).foregroundStyle(MobileTheme.muted).pyHitArea(minSize: 32)
                        }
                        .buttonStyle(.pyPlain)
                        .accessibilityLabel("Dismiss \(branch.branch)")
                    }
                }
            }
            .padding(16)
            .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.large, style: .continuous), tint: MobileTheme.amber.opacity(0.1), fallback: MobileTheme.amber.opacity(0.1))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
