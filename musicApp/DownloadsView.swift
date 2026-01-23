import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showFolderPicker: Bool
    @Binding var showYouTubeDownload: Bool
    @State private var showAddToPlaylist: Download?
    
    var body: some View {
        NavigationView {
            List {
                ForEach(downloadManager.sortedDownloads) { download in
                    DownloadRow(
                        download: download,
                        audioPlayer: audioPlayer,
                        onAddToPlaylist: {
                            showAddToPlaylist = download
                        },
                        onDelete: {
                            downloadManager.deleteDownload(download)
                        }
                    )
                }
            }
            .navigationTitle("Downloads")
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
        }
        .sheet(item: $showAddToPlaylist) { download in
            AddToPlaylistSheet(
                download: download,
                playlistManager: playlistManager,
                onDismiss: { showAddToPlaylist = nil }
            )
        }
    }
}

struct DownloadRow: View {
    let download: Download
    @ObservedObject var audioPlayer: AudioPlayerManager
    let onAddToPlaylist: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Play button / thumbnail
            Button {
                if audioPlayer.currentTrack?.id == download.id {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } else {
                    let track = Track(id: download.id, name: download.name, url: download.url, folderName: "Downloads")
                    audioPlayer.play(track)
                }
            } label: {
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
                    
                    if audioPlayer.currentTrack?.id == download.id && audioPlayer.isPlaying {
                        Color.black.opacity(0.3)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Image(systemName: "pause.fill")
                            .foregroundColor(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            
            Text(download.name)
                .font(.body)
                .lineLimit(1)
            
            Spacer()
            
            Button {
                onAddToPlaylist()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}