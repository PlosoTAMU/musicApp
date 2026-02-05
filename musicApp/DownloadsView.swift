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
                                if audioPlayer.currentTrack?.id == deletedDownload.id {
                                    audioPlayer.stop()
                                }
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
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.black)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .scrollIndicators(.visible)
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
    
    // ✅ ADD THIS HELPER
    private func constructURL(from videoID: String, source: DownloadSource) -> String? {
        switch source {
        case .youtube:
            return "https://www.youtube.com/watch?v=\(videoID)"
        case .spotify:
            return "https://open.spotify.com/track/\(videoID)"
        case .folder:
            return nil
        }
    }

}

struct DownloadRow: View {
    let download: Download
    @ObservedObject var audioPlayer: AudioPlayerManager
    let onAddToPlaylist: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void  // ✅ ADD THIS
    let onRedownload: () -> Void    // ✅ ADD THIS
    
    @State private var showRenameAlert = false  // ✅ ADD THIS
    @State private var newName: String = ""     // ✅ ADD THIS
    
    private var isCurrentlyPlaying: Bool {
        audioPlayer.currentTrack?.id == download.id
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                // ✅ PERFORMANCE: Async thumbnail loading with caching
                ZStack {
                    AsyncThumbnailView(
                        thumbnailPath: download.resolvedThumbnailPath,
                        size: 48,
                        cornerRadius: 8,
                        grayscale: download.pendingDeletion
                    )
                    
                    if isCurrentlyPlaying && audioPlayer.isPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.4))
                            .frame(width: 48, height: 48)
                        Image(systemName: "pause.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 14))
                    }
                }
                .frame(width: 48, height: 48)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(download.name)
                        .font(.body)
                        .fontWeight(isCurrentlyPlaying ? .bold : .regular)
                        .italic(isCurrentlyPlaying)
                        .foregroundColor(download.pendingDeletion ? .gray : .primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Image(systemName: sourceIcon(for: download.source))
                            .font(.system(size: 8))
                        Text(download.source.rawValue.capitalized)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap()
            }
            .contextMenu {  // ✅ ADD THIS
                Button {
                    showRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                if let videoID = download.videoID, !videoID.isEmpty {
                    Button {
                        redownload()
                    } label: {
                        Label("Redownload", systemImage: "arrow.clockwise")
                    }
                }
            }
            
            // Buttons stay outside the tap area
            if !download.pendingDeletion {
                Button(action: onAddToPlaylist) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            
            Button(action: onDelete) {
                Image(systemName: download.pendingDeletion ? "arrow.uturn.backward.circle.fill" : "trash")
                    .font(.body)
                    .foregroundColor(download.pendingDeletion ? .orange : .red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
        .swipeToQueue {
            let folderName = folderName(for: download.source)
            let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName)
            audioPlayer.addToQueue(track)
        }
        .alert("Rename Song", isPresented: $showRenameAlert) {  // ✅ ADD THIS
            TextField("Song name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                onRename(newName)
            }
        } message: {
            Text("Enter a new name for this song")
        }
    }
    
    private func handleTap() {
        guard !download.pendingDeletion else { return }
        
        if audioPlayer.currentTrack?.id == download.id {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
            } else {
                audioPlayer.resume()
            }
        } else {
            let folderName = folderName(for: download.source)
            let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName)
            audioPlayer.play(track)
        }
    }
    
    private func sourceIcon(for source: DownloadSource) -> String {
        switch source {
        case .youtube: return "play.rectangle.fill"
        case .spotify: return "music.note"
        case .folder: return "folder.fill"
        }
    }
    
    private func folderName(for source: DownloadSource) -> String {
        switch source {
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        case .folder: return "Files"
        }
    }
}