import SwiftUI
import AVFoundation

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
                            // ✅ PERFORMANCE: Async thumbnail loading
                            AsyncThumbnailView(
                                thumbnailPath: download.resolvedThumbnailPath,
                                size: 48,
                                cornerRadius: 8
                            )
                            
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

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    var audioPlayer: AudioPlayerManager
    @State private var showAddSongs = false
    @State private var totalDuration: TimeInterval = 0
    @State private var isVisible = false
    @State private var currentPlayingTrackID: UUID?
    @State private var isAudioPlaying = false
    
    var tracks: [Download] {
        playlist.trackIDs.compactMap { id in
            downloadManager.getDownload(byID: id)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
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
                
                Text("\(tracks.count) songs • \(formatDuration(totalDuration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            List {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, download in
                    PlaylistSongRow(
                        download: download,
                        isCurrentlyPlaying: currentPlayingTrackID == download.id,
                        isPlaying: isAudioPlaying,
                        playlist: playlist,
                        onTap: {
                            let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                            audioPlayer.play(track)
                        },
                        onRename: { newName in
                            downloadManager.renameDownload(download, newName: newName)
                        },
                        onRedownload: {
                            if let videoID = download.videoID,
                            let originalURL = constructURL(from: videoID, source: download.source) {
                                downloadManager.startBackgroundDownload(
                                    url: originalURL,
                                    videoID: videoID,
                                    source: download.source,
                                    title: "Redownloading..."
                                )
                            }
                        },
                        onQueue: {
                            let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                            audioPlayer.addToQueue(track)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.black)
                }
                .onMove { source, destination in
                    var trackIDs = playlist.trackIDs
                    trackIDs.move(fromOffsets: source, toOffset: destination)
                    
                    if let playlistIndex = playlistManager.playlists.firstIndex(where: { $0.id == playlist.id }) {
                        playlistManager.playlists[playlistIndex].trackIDs = trackIDs
                        playlistManager.objectWillChange.send()
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
            .scrollIndicators(.visible)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: currentPlayingTrackID != nil ? 65 : 0)
            }
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
            isVisible = true
            currentPlayingTrackID = audioPlayer.currentTrack?.id
            isAudioPlaying = audioPlayer.isPlaying
            updateTotalDuration()
        }
        .onDisappear {
            isVisible = false
        }
        .onReceive(audioPlayer.$currentTrack) { newTrack in
            let newID = newTrack?.id
            if currentPlayingTrackID != newID {
                currentPlayingTrackID = newID
            }
        }
        .onReceive(audioPlayer.$isPlaying) { playing in
            if isAudioPlaying != playing {
                isAudioPlaying = playing
            }
        }
        .onChange(of: playlist.trackIDs) { _ in
            updateTotalDuration()
        }
    }

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
    
    private func updateTotalDuration() {
        let trackURLs = tracks.map { $0.url }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var total: TimeInterval = 0
            for url in trackURLs {
                let asset = AVAsset(url: url)
                let duration = asset.duration.seconds
                if duration.isFinite {
                    total += duration
                }
            }
            
            DispatchQueue.main.async {
                totalDuration = total
            }
        }
    }
    
    private func getAudioDuration(url: URL) -> TimeInterval? {
        let asset = AVAsset(url: url)
        let d = asset.duration.seconds
        return d.isFinite ? d : nil
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

struct PlaylistSongRow: View {
    let download: Download
    let isCurrentlyPlaying: Bool
    let isPlaying: Bool
    let playlist: Playlist
    let onTap: () -> Void
    let onRename: (String) -> Void
    let onRedownload: () -> Void
    let onQueue: () -> Void
    
    @State private var showRenameAlert = false
    @State private var newName: String = ""
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                // ✅ FIXED: Add play/pause icon overlay on thumbnail
                ZStack {
                    AsyncThumbnailView(
                        thumbnailPath: download.resolvedThumbnailPath,
                        size: 48,
                        cornerRadius: 8
                    )
                    
                    // ✅ ADDED: Play/Pause icon overlay
                    if isCurrentlyPlaying && isPlaying {
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
                        .foregroundColor(isCurrentlyPlaying ? .blue : .primary)
                        .lineLimit(1)
                    
                    Text(download.source.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
            .contextMenu {
                Button {
                    newName = download.name
                    showRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                if let videoID = download.videoID, !videoID.isEmpty {
                    Button {
                        onRedownload()
                    } label: {
                        Label("Redownload", systemImage: "arrow.clockwise")
                    }
                }
            }
            .alert("Rename Song", isPresented: $showRenameAlert) {
                TextField("Song name", text: $newName)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    onRename(newName)
                }
            } message: {
                Text("Enter a new name for this song")
            }
            
            // ✅ ADDED: Volume icon when playing
            if isCurrentlyPlaying && isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.blue)
                    .font(.body)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
        .swipeToQueue {
            onQueue()
        }
    }
}