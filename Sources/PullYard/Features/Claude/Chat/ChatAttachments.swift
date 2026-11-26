import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

struct ChatPreviewItem: Identifiable, Sendable {
    let id: String
    let url: URL?
    let data: Data?
    let mediaType: String

    init(image: ChatImage) {
        id = image.id.uuidString
        url = nil
        data = image.data
        mediaType = image.mediaType
    }

    init(file: URL, stamp: TimeInterval = 0) {
        id = file.path + "#" + String(Int(stamp))
        url = file
        data = nil
        mediaType = ""
    }

    var previewURL: URL? {
        if let url { return url }
        guard let data else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PullYardChatPreviews", isDirectory: true)
        let ext = UTType(mimeType: mediaType)?.preferredFilenameExtension ?? "png"
        let file = dir.appendingPathComponent(id).appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? data.write(to: file, options: .atomic)) != nil else { return nil }
        }
        return file
    }

    @MainActor
    static func open(_ items: [ChatPreviewItem], at index: Int) {
        var urls: [URL] = []
        var start = 0
        for (i, item) in items.enumerated() {
            guard let url = item.previewURL else { continue }
            if i == index { start = urls.count }
            urls.append(url)
        }
        ChatQuickLook.shared.show(urls, at: start)
    }
}

final class ChatQuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ChatQuickLook()
    private var urls: [URL] = []
    private var start = 0
    private weak var host: NSWindow?

    func show(_ urls: [URL], at index: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        start = min(max(index, 0), urls.count - 1)
        insert(into: NSApp.keyWindow ?? NSApp.mainWindow)
        if (panel.dataSource as AnyObject?) !== self {
            panel.updateController()
        }
        // The panel picks its controller from the key window's responder chain. When that
        // chain doesn't reach us (key window is a popover or sheet, the app isn't active, or
        // another responder claims the panel first) it opens empty: "No items selected".
        // Feed it directly so a click always shows the file.
        if (panel.dataSource as AnyObject?) !== self {
            panel.dataSource = self
            panel.delegate = self
        }
        panel.reloadData()
        panel.currentPreviewItemIndex = start
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func insert(into window: NSWindow?) {
        guard let window, !(window is QLPreviewPanel) else { return }
        if host === window, window.nextResponder === self { return }
        remove()
        nextResponder = window.nextResponder
        window.nextResponder = self
        host = window
    }

    private func remove() {
        if let host, host.nextResponder === self { host.nextResponder = nextResponder }
        host = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = start
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        if (panel.dataSource as AnyObject?) === self { panel.dataSource = nil }
        if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
        remove()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url = urls[safe: index] else { return nil }
        return url as NSURL
    }
}

enum ChatThumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 240
        return c
    }()

    static func cached(_ id: String) -> NSImage? { cache.object(forKey: id as NSString) }

    static func load(_ item: ChatPreviewItem, maxPixel: Int = 320) async -> NSImage? {
        if let hit = cached(item.id) { return hit }
        let cg = await Task.detached(priority: .utility) { () -> CGImage? in
            let source: CGImageSource?
            if let url = item.url {
                source = CGImageSourceCreateWithURL(url as CFURL, nil)
            } else if let data = item.data {
                source = CGImageSourceCreateWithData(data as CFData, nil)
            } else {
                source = nil
            }
            guard let source else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(image, forKey: item.id as NSString)
        return image
    }
}

struct ChatThumb: View {
    let item: ChatPreviewItem
    var height: CGFloat = 72
    let onOpen: () -> Void
    @State private var image: NSImage?
    @State private var failed = false
    @State private var hover = false

    init(item: ChatPreviewItem, height: CGFloat = 72, onOpen: @escaping () -> Void) {
        self.item = item
        self.height = height
        self.onOpen = onOpen
        _image = State(initialValue: ChatThumbnails.cached(item.id))
    }

    private var width: CGFloat {
        guard let image, image.size.height > 0 else { return height }
        return min(max(height * image.size.width / image.size.height, height * 0.6), height * 2)
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.syText.opacity(Tint.subtle)
                    if failed {
                        Image(systemName: "photo").foregroundStyle(Color.syDim)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(hover ? Color.syLineStrong : Color.syLine))
            .shadow(color: .black.opacity(hover ? 0.12 : 0), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .help("Open preview")
        .accessibilityLabel("Image preview")
        .task(id: item.id) {
            guard image == nil else { return }
            let loaded = await ChatThumbnails.load(item)
            image = loaded
            failed = loaded == nil
        }
    }
}

struct ToolImageStrip: View {
    let calls: [ChatToolCall]

    var body: some View {
        let items = ToolImages.items(calls)
        if !items.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ChatThumb(item: item, height: 80) { ChatPreviewItem.open(items, at: index) }
                }
            }
            .transition(.opacity)
        }
    }
}

enum ToolImages {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]
    static let limit = 8

    static func items(_ calls: [ChatToolCall]) -> [ChatPreviewItem] {
        var out: [ChatPreviewItem] = []
        var seen: Set<String> = []
        for call in calls + calls.flatMap(\.children) {
            let candidates = call.name == "Read" && !call.imageFiles.isEmpty ? call.imageFiles : call.resultImages.map(ChatPreviewItem.init(image:)) + call.imageFiles
            for item in candidates where seen.insert(item.id).inserted {
                out.append(item)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}

struct ToolImageScan: Sendable {
    let id: String
    let name: String
    let folder: String
    let filePath: String?
    let inputs: [String]
    let output: String?
    let startedAt: Date?

    private static let skipped: Set<String> = ["Edit", "MultiEdit", "NotebookEdit", "Grep", "Glob", "LS", "TodoWrite", "Task", "Agent", "WebSearch", "WebFetch", "ExitPlanMode", "AskUserQuestion"]

    private static let pattern = try? NSRegularExpression(pattern: "[^\\s'\"`<>()\\[\\]{}|;,=*]+\\.(?:png|jpe?g|gif|webp|heic)(?![\\w.])", options: [.caseInsensitive])

    init?(_ call: ChatToolCall, folder: String) {
        guard !Self.skipped.contains(call.name) else { return nil }
        id = call.id
        name = call.name
        self.folder = folder
        startedAt = call.startedAt
        if call.name == "Read" || call.name == "Write" {
            guard let path = call.string("file_path"), ToolImages.extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
            filePath = path
            inputs = []
            output = nil
        } else {
            filePath = nil
            inputs = call.input.values.compactMap { $0 as? String }
            output = call.resultText
        }
    }

    func run() -> [ChatPreviewItem] {
        let fm = FileManager.default
        if let filePath {
            guard let url = resolve(filePath), let stamp = Self.stamp(url, fm) else { return [] }
            return [ChatPreviewItem(file: url, stamp: stamp)]
        }
        var out: [ChatPreviewItem] = []
        var seen: Set<String> = []
        let sources = inputs.map { ($0, true) } + (output.map { [($0, false)] } ?? [])
        for (text, isInput) in sources {
            for path in Self.paths(in: text) {
                guard out.count < ToolImages.limit, let url = resolve(path), seen.insert(url.path).inserted,
                      let stamp = Self.stamp(url, fm) else { continue }
                if let startedAt {
                    guard stamp >= startedAt.timeIntervalSince1970 - 3 else { continue }
                } else if !isInput {
                    continue
                }
                out.append(ChatPreviewItem(file: url, stamp: stamp))
            }
        }
        return out
    }

    static func paths(in text: String) -> [String] {
        guard let pattern, text.utf8.count <= 200_000 else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private func resolve(_ raw: String) -> URL? {
        var path = raw
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            guard !folder.isEmpty else { return nil }
            path = (folder as NSString).appendingPathComponent(path)
        }
        return URL(fileURLWithPath: (path as NSString).standardizingPath)
    }

    private static func stamp(_ url: URL, _ fm: FileManager) -> TimeInterval? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeRegular,
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }
}

enum ChatFileMention {
    struct Split {
        let text: String
        let files: [URL]
    }

    static func token(_ url: URL, folder: String) -> String {
        let path = !folder.isEmpty && url.path.hasPrefix(folder + "/") ? String(url.path.dropFirst(folder.count + 1)) : url.path
        return "@" + (path.contains(" ") ? "\"\(path)\"" : path)
    }

    static func compose(_ text: String, files: [URL], folder: String) -> String {
        guard !files.isEmpty else { return text }
        let mentions = files.map { token($0, folder: folder) }.joined(separator: " ")
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? mentions : body + "\n\n" + mentions
    }

    @MainActor private static var memo: [String: Split] = [:]

    @MainActor
    static func split(_ text: String, folder: String) -> Split {
        guard text.contains("@") else { return Split(text: text, files: []) }
        let key = folder + "\u{1}" + text
        if let hit = memo[key] { return hit }
        let result = parse(text, folder: folder)
        if memo.count > 400 { memo.removeAll() }
        memo[key] = result
        return result
    }

    private static let mention = try? NSRegularExpression(pattern: "@\"([^\"]+)\"|@(\\S+)")

    static func parse(_ text: String, folder: String) -> Split {
        var lines = text.components(separatedBy: "\n")
        var files: [URL] = []
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                lines.removeLast()
                continue
            }
            guard let found = mentions(in: trimmed, folder: folder) else { break }
            files = found + files
            lines.removeLast()
        }
        guard !files.isEmpty else { return Split(text: text, files: []) }
        return Split(text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), files: files)
    }

    private static func mentions(in line: String, folder: String) -> [URL]? {
        guard line.hasPrefix("@"), let mention else { return nil }
        let ns = line as NSString
        let matches = mention.matches(in: line, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var rest = line
        var urls: [URL] = []
        for m in matches {
            let range = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let path = (ns.substring(with: range) as NSString).expandingTildeInPath
            let full = path.hasPrefix("/") ? path : (folder as NSString).appendingPathComponent(path)
            guard path.contains(".") || path.contains("/"), FileManager.default.fileExists(atPath: full) else { return nil }
            urls.append(URL(fileURLWithPath: full))
            rest = rest.replacingOccurrences(of: ns.substring(with: m.range), with: "")
        }
        return rest.trimmingCharacters(in: .whitespaces).isEmpty ? urls : nil
    }
}

struct ChatFileChip: View {
    let url: URL
    let onOpen: () -> Void
    var onRemove: (() -> Void)?
    @State private var hover = false

    private var name: String {
        let n = url.lastPathComponent
        guard n.count > 34 else { return n }
        return String(n.prefix(20)) + "…" + String(n.suffix(12))
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(.syCallout)
                        .foregroundStyle(Color.syText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(url.path)
            .accessibilityLabel("Open \(url.lastPathComponent)")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.syCaption2.weight(.semibold))
                        .foregroundStyle(hover ? Color.syMuted : Color.syDim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove file")
                .accessibilityLabel("Remove \(url.lastPathComponent)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.syText.opacity(hover ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).strokeBorder(hover ? Color.syLineStrong : Color.syLine))
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .contextMenu {
            Button("Quick Look") { onOpen() }
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}
