import SwiftUI

struct JiraSettingsSection: View {
    @ObservedObject private var store = JiraStore.shared
    @ObservedObject private var link = LinkClient.shared
    @EnvironmentObject private var feedback: FeedbackCenter
    @State private var importing = false
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(store.sites) { site in
                HStack(spacing: 12) {
                    Image(systemName: "ticket").foregroundStyle(MobileTheme.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.name).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                        Text(site.projectKeys.isEmpty ? site.host : "\(site.host) · \(site.projectKeys.prefix(4).joined(separator: ", "))\(site.projectKeys.count > 4 ? "…" : "")")
                            .mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { store.remove(site) } label: { Label("Remove", systemImage: "trash") }
                }
            }
            if link.mac != nil {
                Button {
                    importing = true
                    Task {
                        defer { importing = false }
                        do {
                            let count = try await link.importJira()
                            feedback.success(String(format: L("Imported %d Jira sites from %@"), count, link.macName))
                        } catch {
                            feedback.error(error, key: "jira-import")
                        }
                    }
                } label: {
                    HStack {
                        Label(String(format: L("Import from %@"), link.macName), systemImage: "desktopcomputer.and.arrow.down")
                        Spacer()
                        if importing { PullYardLoader(size: 22) }
                    }
                }
                .disabled(importing)
            }
            Button { adding = true } label: { Label("Add Jira site", systemImage: "plus.circle") }
        } header: {
            Text("Jira")
        } footer: {
            Text("Tickets mentioned in a pull request's title, branch or description show on its page. Each ticket opens from the Jira site that owns its project, with the rules you set on the Mac.")
        }
        .pyRow()
        .sheet(isPresented: $adding) {
            JiraAddSheet().pySheetStyle()
        }
    }
}

private struct JiraAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Work", text: $name)
                    TextField("acme.atlassian.net", text: $site).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Email", text: $email).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                    SecureField("API token", text: $token)
                } footer: {
                    Text("Create a token at id.atlassian.com → Security → API tokens. For Jira Server or Data Center, leave the email empty and use a personal access token.")
                }
                if let error {
                    Text(error).foregroundStyle(MobileTheme.red).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(BrandBackdrop())
            .navigationTitle("Add Jira site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        PullYardLoader(size: 22)
                    } else {
                        Button("Connect") { connect() }
                            .fontWeight(.semibold)
                            .disabled(site.trimmingCharacters(in: .whitespaces).isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func connect() {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await JiraStore.shared.add(name: name, site: site, email: email, token: token)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct JiraTicketsSection: View {
    let keys: [String]
    let repo: String
    @ObservedObject private var store = JiraStore.shared
    @State private var tickets: [String: JiraTicket] = [:]
    @State private var failures: [String: String] = [:]
    @Environment(\.openURL) private var openURL

    var body: some View {
        if store.isConfigured, !keys.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Jira", systemImage: "ticket").mobileFont(size: 13, weight: .semibold).foregroundStyle(MobileTheme.muted)
                ForEach(keys, id: \.self) { key in
                    if let ticket = tickets[key] {
                        Button { openURL(ticket.url) } label: { card(ticket) }
                            .buttonStyle(.pyPlain)
                    } else if let failure = failures[key] {
                        HStack(spacing: 8) {
                            Text(key).mobileFont(size: 13, weight: .semibold, design: .monospaced).foregroundStyle(MobileTheme.ink)
                            Text(failure).mobileFont(size: 12).foregroundStyle(MobileTheme.muted).lineLimit(2)
                        }
                    } else {
                        HStack(spacing: 8) {
                            PullYardLoader(size: 18)
                            Text(key).mobileFont(size: 13, design: .monospaced).foregroundStyle(MobileTheme.muted)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pyGlass(in: RoundedRectangle(cornerRadius: PYRadius.card, style: .continuous), fallback: MobileTheme.card)
            .task(id: keys.joined() + store.sites.map(\.id).joined()) { await load() }
        }
    }

    private func load() async {
        for key in keys where tickets[key] == nil {
            do {
                tickets[key] = try await store.ticket(key, repo: repo)
                failures[key] = nil
            } catch {
                failures[key] = error.localizedDescription
            }
        }
    }

    private func card(_ ticket: JiraTicket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(ticket.key).mobileFont(size: 13, weight: .semibold, design: .monospaced).foregroundStyle(MobileTheme.accent)
                if let type = ticket.type { Text(type).mobileFont(size: 12).foregroundStyle(MobileTheme.muted) }
                Spacer(minLength: 6)
                Text(ticket.status)
                    .mobileFont(size: 11, weight: .semibold)
                    .foregroundStyle(statusColor(ticket.statusCategory))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(statusColor(ticket.statusCategory).opacity(0.14), in: Capsule())
            }
            Text(ticket.summary).mobileFont(size: 15, weight: .medium).foregroundStyle(MobileTheme.ink).multilineTextAlignment(.leading).lineLimit(3)
            HStack(spacing: 6) {
                if let assignee = ticket.assignee {
                    Image(systemName: "person.crop.circle").font(.system(size: 11))
                    Text(assignee)
                }
                if store.sites.count > 1 {
                    Text("· \(ticket.siteName)")
                }
            }
            .mobileFont(size: 12).foregroundStyle(MobileTheme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileTheme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusColor(_ category: String) -> Color {
        switch category {
        case "done": MobileTheme.green
        case "indeterminate": MobileTheme.accent
        default: MobileTheme.slate
        }
    }
}
