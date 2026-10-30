import AppKit
import ImageIO

/// Decodes images off the main thread, downsampled to screen size, with a small cache
/// so stepping back and forth (and prefetched neighbours) display instantly.
final class ImageLoader {
    private let maxPixelSize: CGFloat
    private let cacheLimit = 8
    private var cache: [URL: NSImage] = [:]
    private var recent: [URL] = []
    private var pending: [URL: [(NSImage?) -> Void]] = [:]
    private let queue = DispatchQueue(label: "ImageLoader", qos: .userInitiated, attributes: .concurrent)

    init() {
        let largest = NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max()
        maxPixelSize = largest ?? 4096
    }

    /// Calls `completion` on the main thread.
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = cache[url] {
            touch(url)
            completion(image)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }
        pending[url] = [completion]
        let maxPixelSize = maxPixelSize
        queue.async {
            let image = Self.decode(url, maxPixelSize: maxPixelSize)
            DispatchQueue.main.async {
                if let image { self.store(image, for: url) }
                for callback in self.pending.removeValue(forKey: url) ?? [] {
                    callback(image)
                }
            }
        }
    }

    func prefetch(_ url: URL) {
        load(url) { _ in }
    }

    /// Full-resolution decode for zooming in; not cached. Calls `completion` on the main thread.
    func loadFull(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        queue.async {
            let image = Self.decode(url, maxPixelSize: nil)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func store(_ image: NSImage, for url: URL) {
        cache[url] = image
        touch(url)
        while recent.count > cacheLimit {
            cache.removeValue(forKey: recent.removeFirst())
        }
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
    }

    /// Decodes at most `maxPixelSize` on the long side (nil = full resolution). The image's size is
    /// always the original pixel size, so zoom levels mean the same whatever was decoded.
    private static func decode(_ url: URL, maxPixelSize: CGFloat?) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSImage(contentsOf: url)
        }
        // Animated GIF/PNG/WebP: let NSImage keep every frame so NSImageView can animate it.
        if CGImageSourceGetCount(source) > 1, isAnimatedFormat(source) {
            return NSImage(contentsOf: url)
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // respect EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return NSImage(contentsOf: url) // e.g. SVG
        }
        let size = originalSize(source, index) ?? NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func originalSize(_ source: CGImageSource, _ index: Int) -> NSSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        // EXIF orientations 5-8 rotate by 90°.
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
    }

    private static func isAnimatedFormat(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) as String? else { return false }
        return ["com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type)
    }
}
