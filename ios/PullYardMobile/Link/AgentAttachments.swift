import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct AgentAttachment: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var mediaType: String
    var data: Data
    var thumbnail: UIImage?

    var isImage: Bool { mediaType.hasPrefix("image/") }
    var payload: PYLinkAttachment { PYLinkAttachment(name: name, mediaType: mediaType, data: data) }
}

enum AgentAttachmentError: LocalizedError {
    case tooLarge(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .tooLarge(name): String(format: L("%@ is larger than 10 MB."), name)
        case let .unreadable(name): String(format: L("Couldn't read %@."), name)
        }
    }
}

enum AgentAttachmentLoader {
    static let maxFileBytes = 10 * 1024 * 1024
    static let maxTotalBytes = 20 * 1024 * 1024
    private static let maxImageSide: CGFloat = 2000

    static func image(_ data: Data, name: String) -> AgentAttachment? {
        guard let source = UIImage(data: data) else { return nil }
        let scale = min(1, maxImageSide / max(source.size.width, source.size.height))
        let size = CGSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else { return nil }
        let base = (name as NSString).deletingPathExtension
        return AgentAttachment(name: (base.isEmpty ? "photo" : base) + ".jpg", mediaType: "image/jpeg", data: jpeg, thumbnail: thumbnail(resized))
    }

    static func file(at url: URL) throws -> AgentAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes { throw AgentAttachmentError.tooLarge(name) }
        guard let data = try? Data(contentsOf: url) else { throw AgentAttachmentError.unreadable(name) }
        return try make(data, name: name, type: type)
    }

    static func make(_ data: Data, name: String, type: UTType?) throws -> AgentAttachment {
        if type?.conforms(to: .image) == true, let image = image(data, name: name) { return image }
        guard data.count <= maxFileBytes else { throw AgentAttachmentError.tooLarge(name) }
        return AgentAttachment(name: name, mediaType: type?.preferredMIMEType ?? "application/octet-stream", data: data, thumbnail: nil)
    }

    static func photo(_ item: PhotosPickerItem) async -> AgentAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        return image(data, name: "photo")
    }

    static func load(_ provider: NSItemProvider) async throws -> AgentAttachment? {
        let name = provider.suggestedName ?? "attachment"
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = try? await data(provider, type: .image),
           let image = image(data, name: name) {
            return image
        }
        let type = provider.registeredContentTypes.first { $0.conforms(to: .data) } ?? provider.registeredContentTypes.first
        guard let type else { return nil }
        let data = try await data(provider, type: type)
        let ext = type.preferredFilenameExtension.map { "." + $0 } ?? ""
        let fileName = (name as NSString).pathExtension.isEmpty ? name + ext : name
        return try make(data, name: fileName, type: type)
    }

    private static func data(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? AgentAttachmentError.unreadable(provider.suggestedName ?? "file")) }
            }
        }
    }

    private static func thumbnail(_ image: UIImage) -> UIImage {
        let side: CGFloat = 120
        let scale = side / min(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

struct AgentAttachmentStrip: View {
    let attachments: [AgentAttachment]
    let remove: (AgentAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let thumbnail = attachment.thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.system(size: 18)).foregroundStyle(MobileTheme.accent)
                                    Text(attachment.name).mobileFont(size: 9, weight: .medium).foregroundStyle(MobileTheme.ink).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .padding(6)
                            }
                        }
                        .frame(width: 60, height: 60)
                        .background(MobileTheme.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MobileTheme.line))
                        Button { withAnimation(.snappy) { remove(attachment) } } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.6), in: Circle())
                                .frame(width: 32, height: 32)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.pyPlain)
                        .offset(x: 9, y: -9)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .padding(.top, 8).padding(.trailing, 8)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

struct AgentDropOverlay: View {
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(MobileTheme.accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(MobileTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                Label("Drop to attach", systemImage: "arrow.down.doc")
                    .mobileFont(size: 15, weight: .semibold)
                    .foregroundStyle(MobileTheme.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .pyGlass(in: Capsule(), fallback: MobileTheme.card)
            }
        }
        .padding(10)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: active)
    }
}
