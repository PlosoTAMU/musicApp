import SwiftUI

struct PlaylistsView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showCreatePlaylist = false
    
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
                                Text("\(playlist.trackIDs.count) songs")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .onDelete(perform: deletePlaylists)
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet(
                playlistManager: playlistManager,
                downloadManager: downloadManager,
                onDismiss: { showCreatePlaylist = false }
            )
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.deletePlaylist(playlistManager.playlists[index])
        }
    }
}