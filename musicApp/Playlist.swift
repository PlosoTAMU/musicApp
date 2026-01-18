import Foundation

struct Playlist: Identifiable {
    let id = UUID()
    let name: String
    var tracks: [Track]
}