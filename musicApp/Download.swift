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
    var thumbnailPath: String?  // Now stores just filename like "song.m4a.jpg"
    var videoID: String?
    var source: DownloadSource
    var pendingDeletion: Bool = false
    
    // FIXED: Resolve thumbnail path at runtime
    var resolvedThumbnailPath: String? {
        guard let filename = thumbnailPath else { return nil }
        
        // If it's already just a filename, construct full path
        if !filename.contains("/") {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent("Thumbnails").appendingPathComponent(filename).path
        }
        
        // If it's an old absolute path, extract filename and reconstruct
        let justFilename = (filename as NSString).lastPathComponent
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Thumbnails").appendingPathComponent(justFilename).path
    }
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil, videoID: String? = nil, source: DownloadSource = .youtube) {
        self.id = id
        self.name = name
        self.url = url
        // FIXED: Store only filename, not full path
        if let path = thumbnailPath {
            self.thumbnailPath = (path as NSString).lastPathComponent
        } else {
            self.thumbnailPath = nil
        }
        self.videoID = videoID
        self.source = source
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