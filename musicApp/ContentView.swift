import SwiftUI
import AVFoundation
import MediaPlayer

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    @State private var showNowPlaying = false
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                DownloadsView(
                    downloadManager: downloadManager,
                    playlistManager: playlistManager,
                    audioPlayer: audioPlayer
                )
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                
                PlaylistsView(
                    playlistManager: playlistManager,
                    downloadManager: downloadManager,
                    audioPlayer: audioPlayer
                )
                .tabItem {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
            .padding(.bottom, audioPlayer.currentTrack != nil ? 64 : 0)
            
            // Mini player
            if audioPlayer.currentTrack != nil {
                MiniPlayerBar(audioPlayer: audioPlayer, showNowPlaying: $showNowPlaying)
                    .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(audioPlayer: audioPlayer, isPresented: $showNowPlaying)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
    }
}