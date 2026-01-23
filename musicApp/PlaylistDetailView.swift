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
        List {
            ForEach(tracks) { download in
                HStack(spacing: 12) {
                    // Reorder handle (only in edit mode)
                    if editMode?.wrappedValue == .active {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.gray)
                    }
                    
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