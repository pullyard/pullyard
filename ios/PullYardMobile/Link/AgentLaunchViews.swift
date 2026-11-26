import SwiftUI

extension PYLinkAccount {
    var display: String { email.map { "\(label) · \($0)" } ?? label }
    var initial: String { String((label.isEmpty ? (email ?? "C") : label).prefix(1)).uppercased() }
}

struct AgentAccountBadge: View {
    let account: PYLinkAccount?

    var body: some View {
        Text(account?.initial ?? "C")
            .mobileFont(size: 11, weight: .bold, design: .rounded)
            .foregroundStyle(MobileTheme.violet)
            .frame(width: 22, height: 22)
            .background(MobileTheme.violet.opacity(0.14), in: Circle())
            .accessibilityLabel(account?.display ?? L("Claude account"))
    }
}

struct AgentAccountChips: View {
    let accounts: [PYLinkAccount]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L("All"), id: "", dot: nil)
                ForEach(accounts) { account in
                    chip(account.display, id: account.id, dot: MobileTheme.violet)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, id: String, dot: Color?) -> some View {
        let selected = selection == id
        return Button {
            withAnimation(.snappy) { selection = id }
        } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).lineLimit(1)
            }
            .mobileFont(size: 13, weight: .semibold)
            .foregroundStyle(selected ? MobileTheme.ink : MobileTheme.muted)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .frame(maxWidth: 220)
            .background(selected ? MobileTheme.accent.opacity(0.14) : MobileTheme.ink.opacity(0.05), in: Capsule())
            .overlay(Capsule().stroke(selected ? MobileTheme.accent.opacity(0.5) : MobileTheme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.pyPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AgentLaunchChoice: Equatable {
    var account: String?
    var environment: String?
}

struct AgentLaunchPickers: View {
    let options: PYLinkOptions
    @Binding var choice: AgentLaunchChoice

    private var environment: PYLinkEnvironment? { options.environments.first { $0.id == choice.environment } }

    var body: some View {
        VStack(spacing: 8) {
            if options.accounts.count > 1 {
                Menu {
                    Picker("Claude account", selection: Binding(get: { choice.account ?? options.active ?? "default" }, set: { choice.account = $0 })) {
                        ForEach(options.accounts) { account in
                            Text(account.display).tag(account.id)
                        }
                    }
                } label: {
                    row(symbol: "person.crop.circle", title: L("Account"), value: options.accounts.first { $0.id == (choice.account ?? options.active) }?.display ?? L("Default"))
                }
            }
            if !options.environments.isEmpty {
                Menu {
                    Picker("Environment", selection: Binding(get: { choice.environment ?? "" }, set: { choice.environment = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(options.environments) { env in
                            Label(env.name, systemImage: env.icon).tag(env.id)
                        }
                    }
                } label: {
                    row(symbol: environment?.icon ?? "square.stack.3d.up", title: L("Environment"), value: environment?.name ?? L("None"))
                }
            }
            if let environment, !environment.variables.isEmpty {
                Text(String(format: L("Variables from the Mac: %@"), environment.variables.joined(separator: ", ")))
                    .mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
    }

    private func row(symbol: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(MobileTheme.accent).frame(width: 22)
            Text(title).foregroundStyle(MobileTheme.ink)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(MobileTheme.muted).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(MobileTheme.muted)
        }
        .mobileFont(size: 15)
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MobileTheme.line))
        .contentShape(Rectangle())
    }
}

struct NewAgentSessionSheet: View {
    var preferredAccount: String?
    let started: (String) -> Void
    @ObservedObject private var link = LinkClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var choice = AgentLaunchChoice()
    @State private var folder: String?
    @State private var prompt = ""
    @State private var starting = false
    @State private var error: String?
    @State private var loading = false

    private var environment: PYLinkEnvironment? { link.options?.environments.first { $0.id == choice.environment } }
    private var effectiveFolder: String? { folder ?? environment?.folders.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let options = link.options {
                        AgentLaunchPickers(options: options, choice: $choice)
                        folderPicker(options)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("First message").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                            TextField("What should the agent do? (optional)", text: $prompt, axis: .vertical)
                                .lineLimit(3...10)
                                .mobileFont(size: 15)
                                .padding(12)
                                .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MobileTheme.line))
                        }
                        if let error {
                            Text(error).mobileFont(size: 13).foregroundStyle(MobileTheme.red)
                        }
                        Button(action: start) {
                            HStack(spacing: 8) {
                                if starting { PullYardLoader(size: 22, style: .monochrome(.white)) } else { Image(systemName: "sparkles") }
                                Text(starting ? "Starting on \(link.macName)…" : "Start on \(link.macName)")
                            }
                            .mobileFont(size: 16, weight: .semibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Capsule())
                            .pyGlass(in: Capsule(), tint: MobileTheme.coral, interactive: true, fallback: MobileTheme.coral)
                        }
                        .buttonStyle(.pyPlain)
                        .disabled(starting || effectiveFolder == nil)
                    } else if loading {
                        HStack { Spacer(); PullYardLoader(size: 30); Spacer() }.padding(.vertical, 40)
                    } else {
                        PYEmptyState(title: "Update PullYard on your Mac", message: "Starting new sessions from the iPhone needs the latest PullYard on the Mac.")
                    }
                }
                .padding(16)
            }
            .background(BrandBackdrop())
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            choice.account = preferredAccount ?? link.options?.active
            if link.options == nil {
                loading = true
                await link.loadOptions()
                loading = false
                if choice.account == nil { choice.account = link.options?.active }
            }
        }
        .onChange(of: choice.environment) { _, _ in
            if let environment, let start = environment.folders.first { folder = start }
        }
    }

    private func folderPicker(_ options: PYLinkOptions) -> some View {
        let envFolders = environment?.folders ?? []
        let projects = options.projects.filter { !envFolders.contains($0.path) }
        return Menu {
            if !envFolders.isEmpty {
                Section(environment?.name ?? "") {
                    ForEach(envFolders, id: \.self) { path in
                        Button { folder = path } label: { Label((path as NSString).lastPathComponent, systemImage: path == effectiveFolder ? "checkmark" : "folder") }
                    }
                }
            }
            Section("Recent projects") {
                ForEach(projects) { project in
                    Button { folder = project.path } label: { Label(project.name, systemImage: project.path == effectiveFolder ? "checkmark" : "folder") }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill").foregroundStyle(MobileTheme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(effectiveFolder.map { ($0 as NSString).lastPathComponent } ?? L("Choose a project")).foregroundStyle(MobileTheme.ink).lineLimit(1)
                    if let path = effectiveFolder {
                        Text(path).mobileFont(size: 11).foregroundStyle(MobileTheme.muted).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(MobileTheme.muted)
            }
            .mobileFont(size: 15)
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MobileTheme.line))
            .contentShape(Rectangle())
        }
        .disabled(envFolders.isEmpty && projects.isEmpty)
    }

    private func start() {
        guard let folder = effectiveFolder else { return }
        starting = true
        error = nil
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { starting = false }
            do {
                let session = try await link.startSession(folder: folder, account: choice.account, environment: choice.environment, prompt: text.isEmpty ? nil : text)
                dismiss()
                started(session)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
