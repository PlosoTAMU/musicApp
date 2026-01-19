import SwiftUI

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
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
                .listStyle(.plain)
                
                // Now Playing Bar
                if audioPlayer.currentTrack != nil {
                    NowPlayingBar(audioPlayer: audioPlayer)
                }
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

// MARK: - Now Playing Bar
struct NowPlayingBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    var body: some View {
        HStack(spacing: 16) {
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(audioPlayer.currentTrack?.name ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text(audioPlayer.currentTrack?.folderName ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Previous button
            Button {
                audioPlayer.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            
            // Play/Pause button
            Button {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            // Next button
            Button {
                audioPlayer.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}