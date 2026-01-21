import Foundation

struct Track: Identifiable, Codable {
    let id: UUID
    let name: String
    let url: URL
    let folderName: String
    
    init(id: UUID = UUID(), name: String, url: URL, folderName: String) {
        self.id = id
        self.name = name
        self.url = url
        self.folderName = folderName
    }
}