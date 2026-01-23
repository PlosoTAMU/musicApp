import Foundation

struct Download: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    var thumbnailPath: String?
    
    init(id: UUID = UUID(), name: String, url: URL, thumbnailPath: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.thumbnailPath = thumbnailPath
    }
}