import Foundation
import SwiftUI

class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [Track] = []
    
    private let playlistsFileURL: URL
    
    init() {
        // Set up file path for saving playlists
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        playlistsFileURL = documentsPath.appendingPathComponent("playlists.json")
        
        // Load saved playlists on init
        loadPlaylists()
    }
    
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
            savePlaylists()
        }
    }
    
    func addYouTubeTrack(_ track: Track) {
        allTracks.append(track)
        
        if let index = playlists.firstIndex(where: { $0.name == "YouTube Downloads" }) {
            playlists[index].tracks.append(track)
        } else {
            let playlist = Playlist(name: "YouTube Downloads", tracks: [track])
            playlists.append(playlist)
        }
        
        savePlaylists()
    }
    
    func removePlaylist(_ playlist: Playlist) {
        allTracks.removeAll { track in
            playlist.tracks.contains(where: { $0.id == track.id })
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }
    
    // MARK: - Persistence
    
    private func savePlaylists() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(PlaylistsData(playlists: playlists, allTracks: allTracks))
            try data.write(to: playlistsFileURL)
            print("✅ [PlaylistManager] Playlists saved")
        } catch {
            print("❌ [PlaylistManager] Failed to save playlists: \(error)")
        }
    }
    
    private func loadPlaylists() {
        guard FileManager.default.fileExists(atPath: playlistsFileURL.path) else {
            print("ℹ️ [PlaylistManager] No saved playlists found")
            return
        }
        
        do {
            let data = try Data(contentsOf: playlistsFileURL)
            let decoder = JSONDecoder()
            let playlistsData = try decoder.decode(PlaylistsData.self, from: data)
            
            self.playlists = playlistsData.playlists
            self.allTracks = playlistsData.allTracks
            
            print("✅ [PlaylistManager] Loaded \(playlists.count) playlists with \(allTracks.count) tracks")
            
            // Debug: Check if files actually exist
            for track in allTracks {
                let exists = FileManager.default.fileExists(atPath: track.url.path)
                print("📂 [PlaylistManager] Track '\(track.name)': exists=\(exists), path=\(track.url.path)")
            }
            
        } catch {
            print("❌ [PlaylistManager] Failed to load playlists: \(error)")
        }
    }
    func deleteTrack(_ track: Track, from playlist: Playlist) {
        // Remove from all tracks
        allTracks.removeAll { $0.id == track.id }
        
        // Remove from specific playlist
        if let playlistIndex = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[playlistIndex].tracks.removeAll { $0.id == track.id }
            
            // If playlist is now empty and not YouTube Downloads, remove it
            if playlists[playlistIndex].tracks.isEmpty && playlists[playlistIndex].name != "YouTube Downloads" {
                playlists.remove(at: playlistIndex)
            }
        }
        
        savePlaylists()
    }
}

// Helper struct for encoding/decoding
private struct PlaylistsData: Codable {
    let playlists: [Playlist]
    let allTracks: [Track]
}