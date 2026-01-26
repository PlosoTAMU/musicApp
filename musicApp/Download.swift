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
    var pendingDeletion: Bool = false
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil, videoID: String? = nil, source: DownloadSource = .youtube) {
        self.id = id
        self.name = name
        self.url = url
        self.thumbnailPath = thumbnailPath
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