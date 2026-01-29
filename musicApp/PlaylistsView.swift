import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showCreatePlaylist = false
    @State private var refreshID = UUID()
    
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
                                
                                let trackCount = playlistManager.getTracks(for: playlist, from: downloadManager).count
                                let duration = playlistManager.getTotalDuration(for: playlist, from: downloadManager)
                                
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
            .scrollIndicators(.visible) // FIXED: Add scroll bar
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
                // Force refresh
                refreshID = UUID()
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet(
                playlistManager: playlistManager,
                downloadManager: downloadManager,
                onDismiss: { 
                    showCreatePlaylist = false
                    refreshID = UUID()
                }
            )
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.deletePlaylist(playlistManager.playlists[index])
        }
        refreshID = UUID()
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}