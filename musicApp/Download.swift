import Foundation

struct Download: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    var thumbnailPath: String?
    var videoID: String?  // Store video ID for duplicate detection
    var pendingDeletion: Bool = false  // For gray delete state
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil, videoID: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.thumbnailPath = thumbnailPath
        self.videoID = videoID
        self.pendingDeletion = false
    }
}