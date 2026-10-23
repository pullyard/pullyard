import Foundation
import SwiftUI

struct StackNote: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case note, question, decision
        var id: String { rawValue }
        var title: String {
            switch self {
            case .note: return "Note"
            case .question: return "Question"
            case .decision: return "Decision"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var text: String
    var updated: Date
    var source: String?

    init(id: UUID = UUID(), kind: Kind = .note, text: String = "", updated: Date = Date(), source: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.updated = updated
        self.source = source
    }
}

@Observable
@MainActor
final class StackNotes {
    nonisolated static let defaultFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PullYard", isDirectory: true)
        .appendingPathComponent("stack-notes.json")

    static let shared: StackNotes = {
        let store = StackNotes(file: defaultFile)
        store.watchInbox()
        return store
    }()

    nonisolated static func read(key: String) -> [StackNote] {
        let saved = (try? Data(contentsOf: defaultFile)).flatMap { try? JSONDecoder().decode([String: [StackNote]].self, from: $0) }?[key] ?? []
        let pending = StackNotesInbox.peek().filter { $0.key == key }.map { StackNote(kind: $0.kind, text: $0.text, updated: $0.created, source: "Claude") }
        return saved + pending
    }

    private(set) var byPR: [String: [StackNote]] = [:]
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var inboxSource: DispatchSourceFileSystemObject?

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([String: [StackNote]].self, from: data) {
            byPR = decoded
        }
    }

    nonisolated static func key(account: String?, host: String, repo: RepoRef, number: Int) -> String {
        "\(account?.lowercased() ?? "")|\(host)|\(repo.full.lowercased())#\(number)"
    }

    func notes(_ key: String) -> [StackNote] {
        byPR[key] ?? []
    }

    func hasNotes(_ key: String) -> Bool {
        byPR[key]?.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }

    func replace(_ key: String, with drafts: [StackNote]) {
        let old = Dictionary((byPR[key] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept: [StackNote] = drafts.compactMap { d in
            guard !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if let o = old[d.id], o.text == d.text, o.kind == d.kind { return o }
            var n = d
            n.updated = Date()
            return n
        }
        guard kept != (byPR[key] ?? []) else { return }
        byPR[key] = kept.isEmpty ? nil : kept
        scheduleSave()
    }

    func importInbox() {
        let entries = StackNotesInbox.drain()
        guard !entries.isEmpty else { return }
        for e in entries {
            byPR[e.key, default: []].append(StackNote(kind: e.kind, text: e.text, updated: e.created, source: "Claude"))
        }
        scheduleSave()
    }

    private func watchInbox() {
        let dir = StackNotesInbox.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        importInbox()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.importInbox() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        inboxSource = source
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write(byPR.filter { !$0.value.isEmpty })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func write(_ value: [String: [StackNote]]) {
        let url = file
        guard let data = try? JSONEncoder().encode(value) else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

extension StackNote.Kind {
    var color: Color {
        switch self {
        case .note: return .syAmber
        case .question: return .sySky
        case .decision: return .syGreen
        }
    }
}

struct StickyNote: View {
    let notes: [StackNote]
    @State private var hovered = false

    var body: some View {
        let sorted = notes.sorted { $0.updated > $1.updated }
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "note.text")
                Text(plural(sorted.count, "note", "notes")).fontWeight(.semibold)
                Spacer(minLength: 0)
                Text(hovered ? "Open" : "").foregroundStyle(Color.syMuted)
                Image(systemName: "square.and.pencil").foregroundStyle(hovered ? Color.syText : Color.syMuted)
            }
            .font(.syCaption2)
            .foregroundStyle(Color.syAmber)
            ForEach(sorted.prefix(2)) { n in
                HStack(spacing: 5) {
                    Circle().fill(n.kind.color).frame(width: 6, height: 6)
                    Text(n.kind.title).font(.syCaption2.weight(.semibold)).foregroundStyle(n.kind.color)
                    if n.source != nil {
                        Image(systemName: "terminal").font(.syCaption2).foregroundStyle(Color.syMuted).help("Added by Claude")
                    }
                    Text(n.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.syCaption)
                        .foregroundStyle(Color.syText)
                        .lineLimit(1)
                }
            }
            if sorted.count > 2 {
                Text("+\(sorted.count - 2) more").font(.syCaption2).foregroundStyle(Color.syMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.syAmber.opacity(hovered ? 0.22 : 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.syAmber.opacity(hovered ? 0.8 : 0.45), lineWidth: hovered ? 1.5 : 1))
        .onHover { h in withAnimation(Motion.fade) { hovered = h } }
        .help("Click to read and edit all notes")
    }
}

struct StackNotesEditor: View {
    let key: String
    let number: Int
    let title: String
    let store: StackNotes
    let onClose: () -> Void
    @State private var seen: Set<UUID> = []
    @State private var drafts: [StackNote] = []
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(Color.syAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes on #\(number)").font(.syHeadline)
                    Text(title).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.syCallout.weight(.semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach($drafts) { $note in
                        NoteEditorRow(note: $note) {
                            drafts.removeAll { $0.id == note.id }
                            commit()
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    drafts.append(StackNote())
                } label: {
                    Label("Add note", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("Only on this Mac").font(.syCaption).foregroundStyle(Color.syDim)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.syRaised))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.syLineStrong))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onAppear {
            drafts = store.notes(key)
            if drafts.isEmpty { drafts = [StackNote()] }
            seen = Set(drafts.map(\.id))
        }
        .onChange(of: drafts) {
            seen.formUnion(drafts.map(\.id))
            scheduleCommit()
        }
        .onChange(of: store.notes(key)) { _, stored in
            let arrived = stored.filter { !seen.contains($0.id) }
            guard !arrived.isEmpty else { return }
            drafts.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            drafts += arrived
        }
        .onDisappear {
            commit()
            store.flush()
        }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        commitTask?.cancel()
        commitTask = nil
        store.replace(key, with: drafts)
    }
}

private struct NoteEditorRow: View {
    @Binding var note: StackNote
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $note.kind) {
                    ForEach(StackNote.Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete note")
            }
            TextEditor(text: $note.text)
                .font(.syCallout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.syAmber.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.syLineStrong))
        }
    }
}
