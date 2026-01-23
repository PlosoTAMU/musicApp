import Foundation

struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]  // Store IDs instead of full tracks
    
    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
    }
}