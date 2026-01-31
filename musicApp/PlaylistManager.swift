import Foundation
import SwiftUI
import AVFoundation

class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    
    private let playlistsFileURL: URL
    
    init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        playlistsFileURL = documentsPath.appendingPathComponent("playlists.json")
        loadPlaylists()
    }
    
    
    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }
    
    func addToPlaylist(_ playlistID: UUID, downloadID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        
        if !playlists[index].trackIDs.contains(downloadID) {
            playlists[index].trackIDs.append(downloadID)
            savePlaylists()
        }
    }
    
    func removeFromPlaylist(_ playlistID: UUID, downloadID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == downloadID }
        savePlaylists()
    }
    
    func removeFromAllPlaylists(_ downloadID: UUID) {
        var changed = false
        for i in 0..<playlists.count {
            if playlists[i].trackIDs.contains(downloadID) {
                playlists[i].trackIDs.removeAll { $0 == downloadID }
                changed = true
            }
        }
        if changed {
            savePlaylists()
        }
    }
    
    func moveTrack(in playlistID: UUID, from source: IndexSet, to destination: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }
    
    func deletePlaylist(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }
    
    func getTracks(for playlist: Playlist, from downloadManager: DownloadManager) -> [Download] {
        playlist.trackIDs.compactMap { downloadManager.getDownload(byID: $0) }
    }
    
    func getTotalDuration(for playlist: Playlist, from downloadManager: DownloadManager) -> TimeInterval {
        let tracks = getTracks(for: playlist, from: downloadManager)
        var totalDuration: TimeInterval = 0
        
        for track in tracks {
            if let duration = getAudioDuration(url: track.url) {
                totalDuration += duration
            }
        }
        
        return totalDuration
    }
    
    private func getAudioDuration(url: URL) -> TimeInterval? {
        let asset = AVAsset(url: url)
        return asset.duration.seconds
    }
    
    func savePlaylists() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(playlists)
            try data.write(to: playlistsFileURL)
            print("✅ [PlaylistManager] Saved \(playlists.count) playlists")
            objectWillChange.send()
        } catch {
            print("❌ [PlaylistManager] Failed to save: \(error)")
        }
    }
    
    private func loadPlaylists() {
        guard FileManager.default.fileExists(atPath: playlistsFileURL.path) else {
            print("ℹ️ [PlaylistManager] No saved playlists")
            return
        }
        
        do {
            let data = try Data(contentsOf: playlistsFileURL)
            let decoder = JSONDecoder()
            playlists = try decoder.decode([Playlist].self, from: data)
            print("✅ [PlaylistManager] Loaded \(playlists.count) playlists")
        } catch {
            print("❌ [PlaylistManager] Failed to load: \(error)")
        }
    }
}