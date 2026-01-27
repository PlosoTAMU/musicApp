import SwiftUI
import AVFoundation

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showAddSongs = false
    @State private var totalDuration: TimeInterval = 0
    
    var tracks: [Download] {
        // Get tracks in the order specified by trackIDs
        playlist.trackIDs.compactMap { id in
            downloadManager.getDownload(byID: id)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Play/Shuffle buttons with total duration
            VStack(spacing: 8) {
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
                
                // Total runtime
                Text("\(tracks.count) songs • \(formatDuration(totalDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            // Song list with drag to reorder
            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, download in
                    PlaylistSongRow(
                        download: download,
                        audioPlayer: audioPlayer,
                        playlist: playlist,
                        onTap: {
                            let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                            audioPlayer.play(track)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.black)
                }
                .onMove { source, destination in
                    var trackIDs = playlist.trackIDs
                    trackIDs.move(fromOffsets: source, toOffset: destination)
                    
                    // Update playlist with new order
                    if let playlistIndex = playlistManager.playlists.firstIndex(where: { $0.id == playlist.id }) {
                        playlistManager.playlists[playlistIndex].trackIDs = trackIDs
                        playlistManager.objectWillChange.send()
                        // Force save
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            playlistManager.savePlaylists()
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let download = tracks[index]
                        playlistManager.removeFromPlaylist(playlist.id, downloadID: download.id)
                    }
                    updateTotalDuration()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .environment(\.editMode, .constant(.active))
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSongs = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSongs) {
            SelectSongsSheet(
                playlistID: playlist.id,
                playlistManager: playlistManager,
                downloadManager: downloadManager,
                onDismiss: {
                    updateTotalDuration()
                }
            )
        }
        .onAppear {
            updateTotalDuration()
        }
        .onChange(of: playlist.trackIDs) { _ in
            updateTotalDuration()
        }
    }
    
    private func updateTotalDuration() {
        totalDuration = 0
        for track in tracks {
            if let duration = getAudioDuration(url: track.url) {
                totalDuration += duration
            }
        }
    }
    
    private func getAudioDuration(url: URL) -> TimeInterval? {
        let asset = AVAsset(url: url)
        return asset.duration.seconds
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - Playlist Song Row with Swipe to Queue
struct PlaylistSongRow: View {
    let download: Download
    @ObservedObject var audioPlayer: AudioPlayerManager
    let playlist: Playlist
    let onTap: () -> Void
    @State private var offset: CGFloat = 0
    @State private var showQueueAdded = false
    @State private var isSwiping = false
    
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
                
                Text(download.name)
                    .font(.body)
                    .lineLimit(1)
                
                Spacer()
                
                if audioPlayer.currentTrack?.id == download.id && audioPlayer.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black)
            .contentShape(Rectangle())
            .offset(x: offset)
            .onTapGesture {
                if !isSwiping {
                    onTap()
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { gesture in
                        isSwiping = true
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
                            let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
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
                        
                        // Reset swipe state after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isSwiping = false
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

// MARK: - Select Songs Sheet for adding to playlist
struct SelectSongsSheet: View {
    let playlistID: UUID
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    let onDismiss: () -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(downloadManager.sortedDownloads) { download in
                    Button {
                        playlistManager.addToPlaylist(playlistID, downloadID: download.id)
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
                            
                            Text(download.name)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Spacer()
                            
                            if let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }),
                               playlist.trackIDs.contains(download.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
                }
            }
        }
    }
}