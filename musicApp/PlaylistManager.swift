import Foundation

class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [Track] = []
    
    var everythingPlaylist: Playlist {
        Playlist(name: "Everything", tracks: allTracks)
    }
    
    var youtubePlaylist: Playlist? {
        playlists.first(where: { $0.name == "YouTube Downloads" })
    }
    
    func addFolder(url: URL) {
        let folderName = url.lastPathComponent
        var newTracks: [Track] = []
        
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "mp3" || fileURL.pathExtension.lowercased() == "m4a" {
                    let name = fileURL.deletingPathExtension().lastPathComponent
                    let track = Track(name: name, url: fileURL, folderName: folderName)
                    newTracks.append(track)
                    allTracks.append(track)
                }
            }
        }
        
        if !newTracks.isEmpty {
            let playlist = Playlist(name: folderName, tracks: newTracks)
            playlists.append(playlist)
        }
    }
    
    func addYouTubeTrack(_ track: Track) {
        allTracks.append(track)
        
        // Find or create YouTube Downloads playlist
        if let index = playlists.firstIndex(where: { $0.name == "YouTube Downloads" }) {
            playlists[index].tracks.append(track)
        } else {
            let playlist = Playlist(name: "YouTube Downloads", tracks: [track])
            playlists.append(playlist)
        }
    }
    
    func removePlaylist(_ playlist: Playlist) {
        allTracks.removeAll { track in
            playlist.tracks.contains(where: { $0.id == track.id })
        }
        playlists.removeAll { $0.id == playlist.id }
    }
}