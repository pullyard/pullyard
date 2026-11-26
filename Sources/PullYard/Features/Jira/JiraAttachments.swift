import AppKit
import AVKit
import SwiftUI

@MainActor
enum JiraAttachmentStore {
    private static let thumbs: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        return c
    }()
    private static var downloads: [String: Task<URL, Error>] = [:]

    static let thumbnailFileLimit = 20 * 1024 * 1024

    private static var root: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("PullYard/JiraAttachments", isDirectory: true)
    }

    private static func cacheKey(_ a: JiraAttachment, _ connectionID: String?) -> String {
        "\(connectionID ?? "default")/\(a.id)"
    }

    static func localURL(_ a: JiraAttachment, connectionID: String?) -> URL {
        let safeName = a.filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return root
            .appendingPathComponent(connectionID ?? "default", isDirectory: true)
            .appendingPathComponent(a.id, isDirectory: true)
            .appendingPathComponent(safeName.isEmpty ? "attachment" : safeName)
    }

    static func cachedFile(_ a: JiraAttachment, connectionID: String?) -> URL? {
        let url = localURL(a, connectionID: connectionID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func file(_ a: JiraAttachment, connectionID: String?) async throws -> URL {
        if let hit = cachedFile(a, connectionID: connectionID) { return hit }
        let key = cacheKey(a, connectionID)
        if let running = downloads[key] { return try await running.value }
        guard let client = JiraConnections.shared.client(for: connectionID) else {
            throw APIError(message: "This Jira connection has no API token")
        }
        let destination = localURL(a, connectionID: connectionID)
        let task = Task<URL, Error> {
            try await client.download(at: a.content, to: destination)
            return destination
        }
        downloads[key] = task
        defer { downloads[key] = nil }
        return try await task.value
    }

    static func cachedThumbnail(_ a: JiraAttachment, connectionID: String?) -> NSImage? {
        thumbs.object(forKey: cacheKey(a, connectionID) as NSString)
    }

    static func thumbnail(_ a: JiraAttachment, connectionID: String?) async -> NSImage? {
        let key = cacheKey(a, connectionID) as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        var image: NSImage?
        if let link = a.thumbnail, let client = JiraConnections.shared.client(for: connectionID),
           let data = try? await client.data(at: link) {
            image = NSImage(data: data)
        }
        if image == nil, a.kind == .image, a.size <= thumbnailFileLimit,
           let file = try? await file(a, connectionID: connectionID) {
            image = await downscaled(file)
        }
        if image == nil, a.kind == .video, let file = cachedFile(a, connectionID: connectionID) {
            image = await videoFrame(file)
        }
        if let image { thumbs.setObject(image, forKey: key) }
        return image
    }

    private static func downscaled(_ file: URL, maxPixel: Int = 360) async -> NSImage? {
        let cg = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel, kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        return cg.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2)) }
    }

    private static func videoFrame(_ file: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 360)
        guard let (cg, _) = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
    }

    static func quickLook(_ a: JiraAttachment, connectionID: String?) async throws {
        let url = try await file(a, connectionID: connectionID)
        ChatQuickLook.shared.show([url])
    }

    static func icon(_ a: JiraAttachment) -> String {
        switch a.kind {
        case .image: return "photo"
        case .video: return "film"
        case .other:
            let ext = (a.filename as NSString).pathExtension.lowercased()
            if ext == "pdf" { return "doc.richtext" }
            if ["zip", "gz", "tar", "7z", "rar"].contains(ext) { return "doc.zipper" }
            if ["txt", "log", "json", "xml", "csv", "md"].contains(ext) { return "doc.plaintext" }
            if a.mimeType.hasPrefix("audio/") { return "waveform" }
            return "doc"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

struct JiraAttachmentsSection: View {
    let attachments: [JiraAttachment]
    let connectionID: String?
    @State private var viewing: JiraMediaSelection?
    @State private var opening: String?
    @State private var error: String?

    private var media: [JiraAttachment] { attachments.filter(\.isMedia) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Attachments").font(.syCaption.weight(.semibold)).foregroundStyle(Color.syDim)
                Text("\(attachments.count)").font(.syCaption2.weight(.semibold)).foregroundStyle(Color.syMuted)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.syText.opacity(0.06)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(attachments) { a in
                    JiraAttachmentTile(attachment: a, connectionID: connectionID, busy: opening == a.id) { open(a) }
                        .contextMenu {
                            if a.isMedia { Button("View") { open(a) } }
                            Button("Quick Look") { quickLook(a) }
                            Button("Open in Default App") { openExternally(a) }
                            Button("Show in Finder") { reveal(a) }
                        }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.syCaption).foregroundStyle(Color.syRed)
            }
        }
        .sheet(item: $viewing) { selection in
            JiraMediaViewer(items: media, connectionID: connectionID, index: selection.index)
        }
    }

    private func open(_ a: JiraAttachment) {
        if a.isMedia, let index = media.firstIndex(of: a) {
            viewing = JiraMediaSelection(index: index)
        } else {
            quickLook(a)
        }
    }

    private func withFile(_ a: JiraAttachment, _ action: @escaping (URL) -> Void) {
        opening = a.id
        error = nil
        Task {
            do { action(try await JiraAttachmentStore.file(a, connectionID: connectionID)) } catch { self.error = error.localizedDescription }
            opening = nil
        }
    }

    private func quickLook(_ a: JiraAttachment) { withFile(a) { ChatQuickLook.shared.show([$0]) } }
    private func openExternally(_ a: JiraAttachment) { withFile(a) { NSWorkspace.shared.open($0) } }
    private func reveal(_ a: JiraAttachment) { withFile(a) { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
}

struct JiraMediaSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

struct JiraAttachmentTile: View {
    let attachment: JiraAttachment
    let connectionID: String?
    var busy = false
    let onOpen: () -> Void
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.sySunken)
                    if let thumb {
                        Image(nsImage: thumb).resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    } else {
                        Image(systemName: JiraAttachmentStore.icon(attachment))
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Color.syMuted)
                    }
                    if attachment.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    if busy {
                        Color.black.opacity(0.25)
                        WakeLoader()
                    }
                }
                .frame(height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hover ? Color.syLineStrong : Color.syLine))
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.syCaption).foregroundStyle(Color.syText).lineLimit(1).truncationMode(.middle)
                    Text(JiraAttachmentStore.size(attachment.size)).font(.syCaption2).foregroundStyle(Color.syDim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(attachment.filename)
        .accessibilityLabel("\(attachment.kind == .video ? "Video" : attachment.kind == .image ? "Image" : "File") \(attachment.filename)")
        .task(id: attachment.id) {
            thumb = JiraAttachmentStore.cachedThumbnail(attachment, connectionID: connectionID)
            if thumb == nil { thumb = await JiraAttachmentStore.thumbnail(attachment, connectionID: connectionID) }
        }
    }
}

struct JiraMediaViewer: View {
    let items: [JiraAttachment]
    let connectionID: String?
    @State var index: Int
    @State private var file: URL?
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var loading = false
    @Environment(\.dismiss) private var dismiss

    private var current: JiraAttachment? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                content
                navigation
            }
        }
        .frame(minWidth: 720, idealWidth: 1040, minHeight: 500, idealHeight: 720)
        .task(id: index) { await load() }
        .onDisappear { player?.pause() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let a = current {
                Image(systemName: JiraAttachmentStore.icon(a)).foregroundStyle(Color.syMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.filename).font(.syCallout.weight(.semibold)).foregroundStyle(Color.syText).lineLimit(1).truncationMode(.middle)
                    Text(subtitle(a)).font(.syCaption).foregroundStyle(Color.syMuted).lineLimit(1)
                }
            }
            Spacer()
            if items.count > 1 {
                Text("\(index + 1) of \(items.count)").font(.syCaption.monospacedDigit()).foregroundStyle(Color.syMuted)
            }
            Button { if let file { player?.pause(); ChatQuickLook.shared.show([file]) } } label: { Image(systemName: "eye") }
                .help("Quick Look").accessibilityLabel("Quick Look").disabled(file == nil)
            Button { if let file { NSWorkspace.shared.open(file) } } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in default app").accessibilityLabel("Open in default app").disabled(file == nil)
            Button { if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } } label: { Image(systemName: "folder") }
                .help("Show in Finder").accessibilityLabel("Show in Finder").disabled(file == nil)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.syBar)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26)).foregroundStyle(Color.syAmber)
                Text(error).font(.syCallout).foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center)
                Button("Try again") { Task { await load() } }.controlSize(.small)
            }
            .padding(40)
        } else if let player, current?.kind == .video {
            AttachmentPlayerView(player: player)
        } else if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(12)
        } else if loading {
            VStack(spacing: 10) {
                WakeLoader()
                if let a = current { Text("Loading \(JiraAttachmentStore.size(a.size))…").font(.syCaption).foregroundStyle(.white.opacity(0.7)) }
            }
        }
    }

    @ViewBuilder
    private var navigation: some View {
        if items.count > 1 {
            HStack {
                arrow("chevron.left", label: "Previous", enabled: index > 0, key: .leftArrow) { index -= 1 }
                Spacer()
                arrow("chevron.right", label: "Next", enabled: index < items.count - 1, key: .rightArrow) { index += 1 }
            }
            .padding(.horizontal, 14)
        }
    }

    private func arrow(_ icon: String, label: String, enabled: Bool, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func subtitle(_ a: JiraAttachment) -> String {
        var parts = [JiraAttachmentStore.size(a.size)]
        if let author = a.author { parts.append(author) }
        if let created = a.created { parts.append(Fmt.rel(created)) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        file = nil
        error = nil
        guard let a = current else { return }
        if a.kind == .image { image = JiraAttachmentStore.cachedThumbnail(a, connectionID: connectionID) }
        loading = true
        defer { loading = false }
        do {
            let url = try await JiraAttachmentStore.file(a, connectionID: connectionID)
            guard current?.id == a.id else { return }
            file = url
            switch a.kind {
            case .video:
                let p = AVPlayer(url: url)
                player = p
                p.play()
            case .image:
                if let full = NSImage(contentsOf: url) { image = full } else { error = "Can't show this image here. Try Quick Look." }
            case .other:
                break
            }
        } catch is CancellationError {
        } catch {
            guard current?.id == a.id else { return }
            self.error = error.localizedDescription
        }
    }
}

/// AppKit-backed player. SwiftUI's `VideoPlayer` lives in the `_AVKit_SwiftUI`
/// overlay, which subclasses AVKit types; a SwiftPM build can end up without
/// AVKit itself linked and abort when that metadata is first instantiated.
/// Using `AVPlayerView` directly keeps a hard reference to AVKit.
private struct AttachmentPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
