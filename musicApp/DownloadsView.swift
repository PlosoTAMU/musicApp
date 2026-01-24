import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showFolderPicker: Bool
    @Binding var showYouTubeDownload: Bool
    @State private var showAddToPlaylist: Download?
    @State private var searchText = ""

    var filteredDownloads: [Download] {
        if searchText.isEmpty {
            return downloadManager.sortedDownloads
        } else {
            return downloadManager.sortedDownloads.filter { 
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                ForEach(filteredDownloads) { download in
                    DownloadRow(
                        download: download,
                        audioPlayer: audioPlayer,
                        onAddToPlaylist: {
                            showAddToPlaylist = download
                        },
                        onDelete: {
                            downloadManager.markForDeletion(download) { deletedDownload in
                                // Stop playback if this song is playing
                                if audioPlayer.currentTrack?.id == deletedDownload.id {
                                    audioPlayer.stop()
                                }
                                // Remove from all playlists
                                playlistManager.removeFromAllPlaylists(deletedDownload.id)
                            }
                        }
                    )
                    .opacity(download.pendingDeletion ? 0.5 : 1.0)
                    .overlay(
                        download.pendingDeletion ?
                        HStack {
                            Spacer()
                            Text("Tap trash to undo (5s)")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.trailing, 8)
                        } : nil
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search downloads")
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showYouTubeDownload = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
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
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(download.name)
                            .font(.body)
                            .foregroundColor(download.pendingDeletion ? .gray : .primary)
                            .lineLimit(1)
                        
                        // Show source badge
                        HStack(spacing: 4) {
                            Image(systemName: download.source == .youtube ? "play.rectangle.fill" : 
                                  download.source == .spotify ? "music.note" : "folder.fill")
                                .font(.system(size: 8))
                            Text(download.source.rawValue.capitalized)
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }
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