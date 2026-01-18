import Foundation

class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [Track] = []
    
    var everythingPlaylist: Playlist {
        Playlist(name: "Everything", tracks: allTracks)
    }
    
    func addFolder(url: URL) {
        let folderName = url.lastPathComponent
        var newTracks: [Track] = []
        
        // Start accessing the folder
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        // Get all files in the folder
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                // Check if it's an MP3
                if fileURL.pathExtension.lowercased() == "mp3" {
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    let track = Track(name: name, url: fileURL, folderName: folderName)
                    newTracks.append(track)
                    allTracks.append(track)
                }
            }
        }
        
        // Create playlist from this folder
        if !newTracks.isEmpty {
            let playlist = Playlist(name: folderName, tracks: newTracks)
            playlists.append(playlist)
        }
    }
    
    func removePlaylist(_ playlist: Playlist) {
        // Remove tracks from allTracks
        allTracks.removeAll { track in
            playlist.tracks.contains(where: { $0.id == track.id })
        }
        // Remove playlist
        playlists.removeAll { $0.id == playlist.id }
    }
}