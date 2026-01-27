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
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.black)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
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
    @State private var offset: CGFloat = 0
    @State private var showQueueAdded = false
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Background queue button (only visible when swiping)
            if offset > 5 {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 22))
                            .foregroundColor(Color(red: 0.6, green: 1.0, blue: 0.6))
                        Text("Add to Queue")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(red: 0.6, green: 1.0, blue: 0.6))
                    }
                    .frame(width: 100)
                    .padding(.trailing, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.0, green: 0.4, blue: 0.0), Color(red: 0.0, green: 0.5, blue: 0.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
            
            // Main content
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
                .onTapGesture {
                    if audioPlayer.currentTrack?.id == download.id {
                        if audioPlayer.isPlaying {
                            audioPlayer.pause()
                        } else {
                            audioPlayer.resume()
                        }
                    } else {
                        let folderName = download.source == .youtube ? "YouTube" : 
                                        download.source == .spotify ? "Spotify" : "Files"
                        let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName)
                        audioPlayer.play(track)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(download.name)
                        .font(.body)
                        .foregroundColor(download.pendingDeletion ? .gray : .primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Image(systemName: download.source == .youtube ? "play.rectangle.fill" : 
                              download.source == .spotify ? "music.note" : "folder.fill")
                            .font(.system(size: 8))
                        Text(download.source.rawValue.capitalized)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            .offset(x: offset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { gesture in
                        let translation = gesture.translation.width
                        if translation > 0 {
                            withAnimation(.linear(duration: 0.0)) {
                                offset = min(translation, 120)
                            }
                        }
                    }
                    .onEnded { gesture in
                        let translation = gesture.translation.width
                        let velocity = gesture.predictedEndTranslation.width - translation
                        
                        if translation > 60 || velocity > 50 {
                            // Add to queue
                            let folderName = download.source == .youtube ? "YouTube" : 
                                            download.source == .spotify ? "Spotify" : "Files"
                            let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName)
                            audioPlayer.addToQueue(track)
                            
                            // Haptic feedback
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            
                            showQueueAdded = true
                            
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                offset = 120
                            }
                            
                            // Reset
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    offset = 0
                                    showQueueAdded = false
                                }
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                offset = 0
                            }
                        }
                    }
            )
            
            // Queue added feedback
            if showQueueAdded {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Queued")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        .clipped()
    }
}