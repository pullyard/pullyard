import SwiftUI

struct ReplyTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body: String
}

enum TemplateStore {
    private static let key = "mobile.replyTemplates"

    static let defaults: [ReplyTemplate] = [
        ReplyTemplate(title: "LGTM", body: "LGTM 👍"),
        ReplyTemplate(title: "Thanks", body: "Thanks for the update!"),
        ReplyTemplate(title: "Add tests", body: "Could you add tests for this change?"),
        ReplyTemplate(title: "Nit", body: "Nit: "),
        ReplyTemplate(title: "Description", body: "Could you add a short description of what this changes and why?"),
        ReplyTemplate(title: "Rebase", body: "Please rebase on the latest main before merging."),
    ]

    static func load() -> [ReplyTemplate] {
        guard let data = UserDefaults.standard.data(forKey: key), let items = try? JSONDecoder().decode([ReplyTemplate].self, from: data) else { return defaults }
        return items
    }

    static func save(_ items: [ReplyTemplate]) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct TemplatesBar: View {
    let pick: (ReplyTemplate) -> Void
    @State private var templates = TemplateStore.load()
    @State private var managing = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(templates) { template in
                    Button { pick(template) } label: {
                        Text(template.title)
                            .mobileFont(size: 13, weight: .semibold)
                            .foregroundStyle(MobileTheme.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Capsule())
                            .pyGlassCapsule(interactive: true, fallback: MobileTheme.card)
                    }
                    .buttonStyle(.pyPlain)
                    .accessibilityHint(template.body)
                }
                Button { managing = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .mobileFont(size: 13, weight: .semibold)
                        .foregroundStyle(MobileTheme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .contentShape(Capsule())
                        .pyGlassCapsule(interactive: true, fallback: MobileTheme.card)
                }
                .buttonStyle(.pyPlain)
                .accessibilityLabel("Edit reply templates")
            }
        }
        .sheet(isPresented: $managing, onDismiss: { templates = TemplateStore.load() }) {
            NavigationStack { TemplatesManagerView() }.pySheetStyle()
        }
    }
}

struct TemplatesManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates = TemplateStore.load()
    @State private var editing: ReplyTemplate?

    var body: some View {
        List {
            Section {
                ForEach(templates) { template in
                    Button { editing = template } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.title).mobileFont(size: 15, weight: .semibold).foregroundStyle(MobileTheme.ink)
                            Text(template.body).mobileFont(size: 13).foregroundStyle(MobileTheme.muted).lineLimit(2)
                        }
                    }
                    .pyRow()
                }
                .onDelete { offsets in templates.remove(atOffsets: offsets); TemplateStore.save(templates) }
                .onMove { from, to in templates.move(fromOffsets: from, toOffset: to); TemplateStore.save(templates) }
            } footer: {
                Text("Templates appear above the keyboard when you write a comment, a reply or a review.")
            }
            Section {
                Button { editing = ReplyTemplate(title: "", body: "") } label: { Label("New template", systemImage: "plus.circle.fill") }
                    .pyRow()
                Button(role: .destructive) { templates = TemplateStore.defaults; TemplateStore.save(templates) } label: { Label("Restore defaults", systemImage: "arrow.counterclockwise") }
                    .pyRow()
            }
        }
        .pyListStyle()
        .navigationTitle("Reply templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        .sheet(item: $editing) { template in
            TemplateEditor(template: template) { updated in
                if let index = templates.firstIndex(where: { $0.id == updated.id }) { templates[index] = updated } else { templates.append(updated) }
                TemplateStore.save(templates)
            }
            .pySheetStyle()
            .presentationDetents([.medium, .large])
        }
    }
}

private struct TemplateEditor: View {
    @State var template: ReplyTemplate
    let save: (ReplyTemplate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Short name", text: $template.title)
                    .mobileFont(size: 16, weight: .semibold)
                    .padding(12)
                    .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                TextEditor(text: $template.body)
                    .mobileFont(size: 15)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 160)
                    .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer()
            }
            .padding(18)
            .background(BrandBackdrop())
            .navigationTitle(template.title.isEmpty ? "New template" : template.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(template); dismiss() }
                        .disabled(template.title.trimmingCharacters(in: .whitespaces).isEmpty || template.body.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
