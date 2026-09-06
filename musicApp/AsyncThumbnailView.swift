import SwiftUI
import ImageIO

/// A thumbnail view that loads images asynchronously and caches them in memory
/// to prevent blocking the main thread and reduce lag when scrolling lists
struct AsyncThumbnailView: View {
    let thumbnailPath: String?
    let size: CGFloat
    let cornerRadius: CGFloat
    let grayscale: Bool
    
    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?
    
    init(thumbnailPath: String?, size: CGFloat = 48, cornerRadius: CGFloat = 8, grayscale: Bool = false) {
        self.thumbnailPath = thumbnailPath
        self.size = size
        self.cornerRadius = cornerRadius
        self.grayscale = grayscale
    }
    
    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .grayscale(grayscale ? 1.0 : 0.0)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.smokeRaised)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: max(size * 0.28, 10), weight: .medium))
                            .foregroundColor(Theme.boneFaint)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.seam, lineWidth: 1)
                    )
            }
        }
        .onAppear {
            loadImageAsync()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .onChange(of: thumbnailPath) { _ in
            loadImageAsync()
        }
    }
    
    private func loadImageAsync() {
        loadTask?.cancel()
        
        guard let path = thumbnailPath else {
            image = nil
            return
        }
        
        // ⚡ Check cache first (fast path, no disk I/O). Keyed by path AND
        // size: one shared key meant a 26 pt Up Next decode got reused by the
        // 42 pt mini player (blurry, visibly "different" from Now Playing's
        // full-resolution art) — whichever surface loaded first won.
        let cacheKey = ThumbnailCache.key(path: path, size: size)
        if let cached = ThumbnailCache.shared.get(cacheKey) {
            image = cached
            return
        }
        
        // Cache miss for a *new* path: drop the previous image immediately so
        // we show the placeholder rather than the prior track's artwork while
        // the new thumbnail decodes. This is the fix for the mini-player
        // artwork lagging one song behind when the queue advances.
        image = nil
        
        // ⚡ Capture size locally to avoid referencing self in detached task
        let targetSize = size
        
        loadTask = Task.detached(priority: .utility) {
            // ⚡ Use ImageIO for much faster thumbnail generation
            // Instead of loading full image then downscaling, tell the decoder to only decode at target size
            let url = URL(fileURLWithPath: path)
            let maxPixelSize = Int(targetSize * 2)  // @2x for retina
            
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
            ]
            
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return
            }
            
            let scaledImage = UIImage(cgImage: cgImage)
            
            // Cache it
            ThumbnailCache.shared.set(cacheKey, image: scaledImage)
            
            await MainActor.run {
                if !Task.isCancelled {
                    self.image = scaledImage
                }
            }
        }
    }
}

/// Simple in-memory cache for thumbnails
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    
    private var cache = NSCache<NSString, UIImage>()
    /// Per-path generation, bumped when the file at that path is rewritten
    /// (a thumbnail heal or refetch). Keys embed it, so a cached decode of the
    /// OLD bytes can never be served for the new file. NSCache can't
    /// enumerate, so this is how "invalidate everything for this path" works.
    private var generation: [String: Int] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 100  // Keep up to 100 thumbnails in memory
        cache.totalCostLimit = 100 * 1024 * 1024  // ~100MB limit
    }

    /// Cache key for a decode of `path` at `size` points. Callers that decode
    /// at a bespoke size (Now Playing's full-resolution art) pass their own
    /// label via `variant` instead.
    static func key(path: String, size: CGFloat) -> String {
        shared.key(path: path, variant: "s\(Int(size.rounded()))")
    }

    func key(path: String, variant: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return "\(path)#\(variant)#\(generation[path] ?? 0)"
    }

    /// The file at `path` was rewritten — every cached decode of it is stale.
    func invalidate(path: String) {
        lock.lock(); defer { lock.unlock() }
        generation[path, default: 0] += 1
    }

    func get(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: UIImage) {
        let cost = Int(image.size.width * image.size.height * 4)  // Approximate bytes
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
    
    func clear() {
        cache.removeAllObjects()
    }
}
