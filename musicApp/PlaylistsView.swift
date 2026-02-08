import SwiftUI
import AVFoundation

struct PlaylistsView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    var audioPlayer: AudioPlayerManager
    @State private var showCreatePlaylist = false
    @State private var refreshID = UUID()
    @State private var cachedDurations: [UUID: TimeInterval] = [:]
    @State private var hasCurrentTrack = false
    
    var body: some View {
        NavigationView {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(
                            playlist: playlist,
                            playlistManager: playlistManager,
                            downloadManager: downloadManager,
                            audioPlayer: audioPlayer
                        )
                    } label: {
                        HStack {
                            Image(systemName: "music.note.list")
                                .font(.title2)
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading) {
                                Text(playlist.name)
                                    .font(.headline)
                                
                                let trackCount = playlist.trackIDs.count
                                let duration = cachedDurations[playlist.id] ?? 0
                                
                                Text("\(trackCount) songs • \(formatDuration(duration))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .onDelete(perform: deletePlaylists)
            }
            .id(refreshID)
            .navigationTitle("Playlists")
            .background(Color.black)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: hasCurrentTrack ? 65 : 0)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onAppear {
                hasCurrentTrack = audioPlayer.currentTrack != nil
                refreshID = UUID()
                computeDurationsAsync()
            }
            .onReceive(audioPlayer.$currentTrack) { track in
                hasCurrentTrack = track != nil
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet(
                playlistManager: playlistManager,
                downloadManager: downloadManager,
                onDismiss: { 
                    showCreatePlaylist = false
                    refreshID = UUID()
                    computeDurationsAsync()
                }
            )
        }
    }
    
    /// Compute all playlist durations off the main thread
    private func computeDurationsAsync() {
        let playlists = playlistManager.playlists
        let dm = downloadManager
        
        DispatchQueue.global(qos: .userInitiated).async {
            var durations: [UUID: TimeInterval] = [:]
            
            for playlist in playlists {
                var total: TimeInterval = 0
                for trackID in playlist.trackIDs {
                    if let download = dm.getDownload(byID: trackID) {
                        let asset = AVAsset(url: download.url)
                        total += asset.duration.seconds
                    }
                }
                durations[playlist.id] = total
            }
            
            DispatchQueue.main.async {
                cachedDurations = durations
            }
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.deletePlaylist(playlistManager.playlists[index])
        }
        refreshID = UUID()
        computeDurationsAsync()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}