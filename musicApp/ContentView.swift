import SwiftUI

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    
    var body: some View {
        NavigationView {
            List {
                // Everything playlist (always at top)
                PlaylistRow(
                    playlist: playlistManager.everythingPlaylist,
                    audioPlayer: audioPlayer
                )
                
                // Individual folder playlists
                ForEach(playlistManager.playlists) { playlist in
                    PlaylistRow(
                        playlist: playlist,
                        audioPlayer: audioPlayer
                    )
                }
                .onDelete(perform: deletePlaylists)
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPicker(playlistManager: playlistManager)
            }
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.removePlaylist(playlistManager.playlists[index])
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}