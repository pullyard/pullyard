import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ChatDropItem {
    case file(URL)
    case image(Data, String)
}

@MainActor
struct ChatDropDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .image]
    let chat: ChatSession

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: Self.types) }

    func dropEntered(info: DropInfo) { chat.setDropHover(true) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        chat.setDropHover(true)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { chat.setDropHover(false) }

    func performDrop(info: DropInfo) -> Bool {
        chat.finishDrop()
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        let chat = chat
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in chat.droppedItems.append(.file(url)) }
                }
            } else {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = Self.png(from: data) else { return }
                    Task { @MainActor in chat.droppedItems.append(.image(png, "image/png")) }
                }
            }
        }
        return true
    }

    nonisolated static func png(from data: Data) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}

struct ChatDropOverlay: View {
    let active: Bool

    var body: some View {
        ZStack {
            if active {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.syAccent.opacity(0.07))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(LinearGradient(colors: [BrandMark.violet, BrandMark.sky], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                Label("Drop images to attach, files to mention", systemImage: "arrow.down.doc")
                    .font(.syBody.weight(.medium))
                    .foregroundStyle(Color.syText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .pyGlassCapsule(outline: false)
            }
        }
        .padding(8)
        .allowsHitTesting(false)
        .animation(Motion.fade, value: active)
    }
}

extension ChatImage {
    static let maxBytes = 3_500_000
    static let maxDimension: CGFloat = 2000

    static func fitted(_ image: ChatImage) -> ChatImage? {
        if image.data.count <= maxBytes { return image }
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil) else { return nil }
        for side in [maxDimension, 1400, 1000] {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { continue }
            if jpeg.count <= maxBytes { return ChatImage(data: jpeg, mediaType: "image/jpeg") }
        }
        return nil
    }
}
