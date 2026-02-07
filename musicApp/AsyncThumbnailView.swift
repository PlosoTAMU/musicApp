import SwiftUI

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
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    .grayscale(grayscale ? 1.0 : 0.0)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundColor(.gray)
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
        
        // Check cache first
        if let cached = ThumbnailCache.shared.get(path) {
            image = cached
            return
        }
        
        loadTask = Task.detached(priority: .utility) {
            PerformanceMonitor.shared.start("Thumbnail_Load_\(path)")
            defer { PerformanceMonitor.shared.end("Thumbnail_Load_\(path)") }
            guard let loadedImage = UIImage(contentsOfFile: path) else {
                return
            }
            
            // Downscale to target size for better memory/performance
            let scaledImage = loadedImage.preparingThumbnail(of: CGSize(width: size * 2, height: size * 2)) ?? loadedImage
            
            // Cache it
            ThumbnailCache.shared.set(path, image: scaledImage)
            
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
    
    private init() {
        cache.countLimit = 100  // Keep up to 100 thumbnails in memory
        cache.totalCostLimit = 100 * 1024 * 1024  // ~50MB limit
    }
    
    func get(_ path: String) -> UIImage? {
        cache.object(forKey: path as NSString)
    }
    
    func set(_ path: String, image: UIImage) {
        let cost = Int(image.size.width * image.size.height * 4)  // Approximate bytes
        cache.setObject(image, forKey: path as NSString, cost: cost)
    }
    
    func clear() {
        cache.removeAllObjects()
    }
}
