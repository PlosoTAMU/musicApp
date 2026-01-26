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

struct ActiveDownload: Identifiable {
    let id: UUID
    let videoID: String
    var title: String
    var progress: Double
}

extension Bundle {
    var displayName: String? {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
               object(forInfoDictionaryKey: "CFBundleName") as? String
    }
}