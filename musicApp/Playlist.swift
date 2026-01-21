import Foundation

struct Playlist: Identifiable, Codable {
    let id: UUID
    let name: String
    var tracks: [Track]
    
    init(id: UUID = UUID(), name: String, tracks: [Track]) {
        self.id = id
        self.name = name
        self.tracks = tracks
    }
}