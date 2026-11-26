import AppKit
import SwiftUI

struct AgentEnvironment: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String
    var folders: [String]
    var variableNames: [String]

    var startFolder: String? { folders.first }
    var extraFolders: [String] { Array(folders.dropFirst()) }

    static let icons = ["laptopcomputer", "desktopcomputer", "server.rack", "shippingbox", "hammer", "wrench.and.screwdriver", "terminal", "globe", "iphone", "cube", "leaf", "flame", "bolt", "star", "testtube.2", "paintbrush"]
}

@Observable
@MainActor
final class AgentEnvironments {
    static let shared = AgentEnvironments()
    private static let key = "agents.environments"

    private(set) var items: [AgentEnvironment]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let list = try? JSONDecoder().decode([AgentEnvironment].self, from: data) {
            items = list
        } else {
            items = []
        }
    }

    func environment(id: String?) -> AgentEnvironment? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    func save(_ env: AgentEnvironment, variables: [String: String]) {
        var env = env
        env.variableNames = variables.keys.sorted()
        if let i = items.firstIndex(where: { $0.id == env.id }) { items[i] = env } else { items.append(env) }
        if variables.isEmpty {
            Keychain.delete(account: Self.account(env.id))
        } else if let data = try? JSONEncoder().encode(variables), let text = String(data: data, encoding: .utf8) {
            try? Keychain.save(text, account: Self.account(env.id))
        }
        persist()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        Keychain.delete(account: Self.account(id))
        persist()
    }

    func variables(for id: String) -> [String: String] {
        guard let text = Keychain.load(account: Self.account(id)), let data = text.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private static func account(_ id: String) -> String { "agent-environment-" + id }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct AgentEnvironmentSheet: View {
    var editing: AgentEnvironment?
    var draftName = ""
    var draftFolders: [String] = []
    var onCreate: (AgentEnvironment) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = AgentEnvironment.icons[0]
    @State private var folders: [String] = []
    @State private var variables: [Variable] = []
    @State private var showVariables = false
    @State private var showIcons = false

    struct Variable: Identifiable, Hashable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    private var cleanedVariables: [String: String] {
        var out: [String: String] = [:]
        for v in variables {
            let k = v.key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out[k] = v.value }
        }
        return out
    }

    private var badKey: String? {
        variables.map { $0.key.trimmingCharacters(in: .whitespaces) }.first { k in
            !k.isEmpty && (k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && badKey == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editing == nil ? "New environment" : "Edit environment").font(.syHeadline).foregroundStyle(Color.syText)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.syMuted)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.syCallout.weight(.medium)).foregroundStyle(Color.syText)
                HStack(spacing: 8) {
                    Button { showIcons.toggle() } label: {
                        Image(systemName: icon)
                            .font(.syIcon(13))
                            .foregroundStyle(Color.syText)
                            .frame(width: 30, height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.syText.opacity(0.08)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose icon")
                    .accessibilityLabel("Choose icon")
                    .popover(isPresented: $showIcons, arrowEdge: .bottom) { iconGrid }
                    TextField("My app", text: $name)
                        .textFieldStyle(.plain)
                        .font(.syBody)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySunken))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Folders").font(.syCallout.weight(.medium)).foregroundStyle(Color.syText)
                    Text("(optional)").font(.syCaption).foregroundStyle(Color.syMuted)
                    Spacer()
                    Button { addFolder() } label: { Label("Add", systemImage: "plus") }
                        .controlSize(.small)
                        .tint(Color.syText)
                }
                if folders.isEmpty {
                    Text("Choose the folder the session starts in. More folders are added to the session too.")
                        .font(.syCallout)
                        .foregroundStyle(Color.syMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(Rectangle())
                        .onTapGesture { addFolder() }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                            folderRow(folder, first: index == 0)
                            if index < folders.count - 1 { ClaudeHairline() }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySunken))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
                }
            }
            variablesSection
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .tint(Color.syText)
                Button(editing == nil ? "Create environment" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(.syAgentFill)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 560)
        .surface(.panel)
        .tint(Color.syAgentAccent)
        .onAppear(perform: load)
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(AgentEnvironment.icons, id: \.self) { symbol in
                Button {
                    icon = symbol
                    showIcons = false
                } label: {
                    Image(systemName: symbol)
                        .font(.syIcon(13))
                        .foregroundStyle(symbol == icon ? Color.syAgentAccent : Color.syText)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8).fill(symbol == icon ? Color.syAgentAccent.opacity(0.15) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(symbol)
            }
        }
        .padding(10)
    }

    private func folderRow(_ folder: String, first: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.syIcon(11))
                .foregroundStyle(Color.syCoral)
            VStack(alignment: .leading, spacing: 1) {
                Text((folder as NSString).lastPathComponent).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText)
                Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                    .font(.syCaption)
                    .foregroundStyle(Color.syMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if first {
                Text("Starts here").font(.syCaption2.weight(.semibold)).foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.syText.opacity(0.06)))
            } else {
                Button("Make first") {
                    withAnimation(Motion.smooth) {
                        folders.removeAll { $0 == folder }
                        folders.insert(folder, at: 0)
                    }
                }
                .buttonStyle(.plain)
                .font(.syCaption.weight(.medium))
                .foregroundStyle(Color.syAgentAccent)
            }
            Button { withAnimation(Motion.smooth) { folders.removeAll { $0 == folder } } } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.syMuted)
                .accessibilityLabel("Remove \((folder as NSString).lastPathComponent)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var variablesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.smooth) {
                    showVariables.toggle()
                    if showVariables && variables.isEmpty { variables = [Variable()] }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Environment variables").font(.syCallout.weight(.medium)).foregroundStyle(Color.syText)
                        Text(cleanedVariables.isEmpty ? "None for this environment" : cleanedVariables.keys.sorted().joined(separator: ", "))
                            .font(.syCaption)
                            .foregroundStyle(Color.syMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.syCaption.weight(.semibold))
                        .foregroundStyle(Color.syMuted)
                        .rotationEffect(.degrees(showVariables ? 90 : 0))
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showVariables {
                ClaudeHairline()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($variables) { $v in
                        HStack(spacing: 6) {
                            TextField("NAME", text: $v.key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 170)
                            SecureField("value", text: $v.value)
                                .textFieldStyle(.roundedBorder)
                            Button { variables.removeAll { $0.id == v.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.syMuted)
                                .accessibilityLabel("Remove variable")
                        }
                    }
                    HStack {
                        Button { variables.append(Variable()) } label: { Label("Add variable", systemImage: "plus") }
                            .buttonStyle(.plain)
                            .font(.syCaption.weight(.medium))
                            .foregroundStyle(Color.syAgentAccent)
                        Spacer()
                        if let badKey {
                            Text("“\(badKey)” is not a valid name").font(.syCaption).foregroundStyle(Color.syRed)
                        } else {
                            Text("Values are stored in the macOS Keychain").font(.syCaption).foregroundStyle(Color.syDim)
                        }
                    }
                }
                .padding(14)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.sySunken))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.syLine))
    }

    private func load() {
        if let editing {
            name = editing.name
            icon = editing.icon
            folders = editing.folders
            variables = AgentEnvironments.shared.variables(for: editing.id).sorted { $0.key < $1.key }.map { Variable(key: $0.key, value: $0.value) }
        } else {
            name = draftName
            folders = draftFolders
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
    }

    private func save() {
        let env = AgentEnvironment(
            id: editing?.id ?? UUID().uuidString.lowercased(),
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon,
            folders: folders,
            variableNames: []
        )
        AgentEnvironments.shared.save(env, variables: cleanedVariables)
        if editing == nil { onCreate(env) }
        dismiss()
    }
}
