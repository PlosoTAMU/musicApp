import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showFolderPicker: Bool
    @Binding var showYouTubeDownload: Bool
    @State private var showAddToPlaylist: Download?

    private func downloadFromSpotify() {
        if let clipboardString = UIPasteboard.general.string {
            print("📋 Clipboard: \(clipboardString)")
            // TODO: Add Spotify download logic here
        }
    }
    
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
                            downloadManager.markForDeletion(download)
                        }
                    )
                    .opacity(download.pendingDeletion ? 0.5 : 1.0)
                    .overlay(
                        download.pendingDeletion ?
                        HStack {
                            Spacer()
                            Text("Tap trash to undo")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.trailing, 8)
                        } : nil
                    )
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            showYouTubeDownload = true
                        } label: {
                            Label("YouTube", systemImage: "play.rectangle")
                        }
                        
                        Button {
                            downloadFromSpotify()
                        } label: {
                            Label("Spotify", systemImage: "s.circle.fill")
                        }
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
                HStack(spacing: 12) {
                    ZStack {
                        if let thumbPath = download.thumbnailPath,
                           let image = UIImage(contentsOfFile: thumbPath) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .grayscale(download.pendingDeletion ? 1.0 : 0.0)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 48, height: 48)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                )
                        }
                        
                        if audioPlayer.currentTrack?.id == download.id && audioPlayer.isPlaying {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.black.opacity(0.4))
                            Image(systemName: "pause.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 14))
                        }
                    }
                    
                    Text(download.name)
                        .font(.body)
                        .foregroundColor(download.pendingDeletion ? .gray : .primary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .disabled(download.pendingDeletion)
            
            Spacer()
            
            if !download.pendingDeletion {
                Button {
                    onAddToPlaylist()
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            
            Button {
                onDelete()
            } label: {
                Image(systemName: download.pendingDeletion ? "arrow.uturn.backward.circle.fill" : "trash")
                    .font(.body)
                    .foregroundColor(download.pendingDeletion ? .orange : .red)
            }
            .buttonStyle(.plain)
        }
    }
}