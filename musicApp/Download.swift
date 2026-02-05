import Foundation

enum DownloadSource: String, Codable {
    case youtube
    case spotify
    case folder
}

struct Download: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    var thumbnailPath: String?
    var videoID: String?
    var source: DownloadSource
    var originalURL: String?  // ✅ ADD THIS - store the original download URL
    var pendingDeletion: Bool = false
    
    var resolvedThumbnailPath: String? {
        guard let filename = thumbnailPath else { return nil }
        
        if !filename.contains("/") {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent("Thumbnails").appendingPathComponent(filename).path
        }
        
        let justFilename = (filename as NSString).lastPathComponent
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Thumbnails").appendingPathComponent(justFilename).path
    }
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil, videoID: String? = nil, source: DownloadSource = .youtube, originalURL: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        if let path = thumbnailPath {
            self.thumbnailPath = (path as NSString).lastPathComponent
        } else {
            self.thumbnailPath = nil
        }
        self.videoID = videoID
        self.source = source
        self.originalURL = originalURL  // ✅ ADD THIS
        self.pendingDeletion = false
    }
}

struct ActiveDownload: Identifiable, Equatable {
    let id: UUID
    let videoID: String
    var title: String // FIXED: Changed from `let` to `var` so title can be updated
    var progress: Double
    
    // FIXED: Explicit Equatable conformance for proper SwiftUI diffing
    static func == (lhs: ActiveDownload, rhs: ActiveDownload) -> Bool {
        lhs.id == rhs.id && lhs.videoID == rhs.videoID && lhs.title == rhs.title && lhs.progress == rhs.progress
    }
}

extension Bundle {
    var displayName: String? {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
               object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}