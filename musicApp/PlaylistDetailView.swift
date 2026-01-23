import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Environment(\.editMode) var editMode
    
    var tracks: [Download] {
        playlistManager.getTracks(for: playlist, from: downloadManager)
    }
    
    var body: some View {
    VStack(spacing: 0) {
        // Play/Shuffle buttons at top
        HStack(spacing: 16) {
            Button {
                let tracks = self.tracks.map { download in
                    Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                }
                audioPlayer.loadPlaylist(tracks, shuffle: false)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Play All")
                }
                .font(.subheadline)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.blue)
                .cornerRadius(8)
            }
            
            Button {
                let tracks = self.tracks.map { download in
                    Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                }
                audioPlayer.loadPlaylist(tracks, shuffle: true)
            } label: {
                HStack {
                    Image(systemName: "shuffle")
                    Text("Shuffle")
                }
                .font(.subheadline)
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.green)
                .cornerRadius(8)
            }
        }
        .padding()
        List {
            ForEach(tracks) { download in
                HStack(spacing: 12) {
                    
                    // Thumbnail
                    ZStack {
                        if let thumbPath = download.thumbnailPath,
                           let image = UIImage(contentsOfFile: thumbPath) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 48, height: 48)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .foregroundColor(.gray)
                                )
                        }
                    }
                    
                    // Name
                    Text(download.name)
                        .font(.body)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Playing indicator
                    if audioPlayer.currentTrack?.id == download.id && audioPlayer.isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundColor(.blue)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                    audioPlayer.play(track)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    let download = tracks[index]
                    playlistManager.removeFromPlaylist(playlist.id, downloadID: download.id)
                }
            }
            .onMove { source, destination in
                playlistManager.moveTrack(in: playlist.id, from: source, to: destination)
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
    }
}