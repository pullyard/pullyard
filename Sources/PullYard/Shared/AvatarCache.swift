import AppKit
import ImageIO

/// Decoded, downsampled avatars kept in memory so list rows that scroll back
/// into view draw their image in the same frame instead of restarting a load.
/// SwiftUI's AsyncImage has no memory cache: every recycled row went back to
/// the placeholder, re-read URLCache and decoded on the next runloop turn,
/// which showed up as dropped frames while scrolling.
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()

    nonisolated(unsafe) private let images = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        images.countLimit = 600
    }

    nonisolated func cached(_ url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func image(for url: URL, pixels: Int) async -> NSImage? {
        if let hit = cached(url) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return Self.decode(data, pixels: pixels)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL) }
        return image
    }

    nonisolated private static func decode(_ data: Data, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, pixels)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
