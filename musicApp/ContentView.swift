import SwiftUI

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    
    var body: some View {
        NavigationView {
            List {
                PlaylistRow(
                    playlist: playlistManager.everythingPlaylist,
                    audioPlayer: audioPlayer
                )
                
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showYouTubeDownload = true
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                }
                
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
            .sheet(isPresented: $showYouTubeDownload) {
                YouTubeDownloadView(playlistManager: playlistManager)
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