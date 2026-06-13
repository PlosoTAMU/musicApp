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
            ZStack {
                AppBackground()
                
                List {
                    ForEach(downloadManager.sortedDownloads) { download in
                        Button {
                            playlistManager.addToPlaylist(playlistID, downloadID: download.id)
                        } label: {
                            HStack(spacing: 12) {
                                AsyncThumbnailView(
                                    thumbnailPath: download.resolvedThumbnailPath,
                                    size: 48,
                                    cornerRadius: 10
                                )
                                
                                Text(download.name)
                                    .font(Theme.body(15, weight: .medium))
                                    .foregroundColor(Theme.bone)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                if let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }),
                                   playlist.trackIDs.contains(download.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Theme.emberLight)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                        onDismiss()
                    }
                    .font(Theme.body(15, weight: .semibold))
                    .foregroundColor(Theme.emberLight)
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
    @State private var currentPlayingTrackID: UUID?
    @State private var isAudioPlaying = false
    
    var tracks: [Download] {
        playlist.trackIDs.compactMap { id in
            downloadManager.getDownload(byID: id)
        }
    }
    
    var body: some View {
        ZStack {
            AppBackground()
            
            VStack(spacing: 0) {
                // Header card: cover, stats, actions
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        AsyncThumbnailView(
                            thumbnailPath: tracks.first?.resolvedThumbnailPath,
                            size: 72,
                            cornerRadius: 14
                        )
                        
                        VStack(alignment: .leading, spacing: 5) {
                            SectionEyebrow("Playlist")
                            Text("\(tracks.count) songs  •  \(formatDuration(totalDuration))")
                                .font(Theme.caption(12))
                                .foregroundColor(Theme.boneDim)
                        }
                        
                        Spacer(minLength: 0)
                    }
                    
                    PlaylistActionButtons(
                        tracks: tracks,
                        playlistName: playlist.name,
                        audioPlayer: audioPlayer
                    )
                }
                .padding(16)
                .surfaceCard()
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
                
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, download in
                        PlaylistSongRow(
                            download: download,
                            isCurrentlyPlaying: currentPlayingTrackID == download.id,
                            isPlaying: isAudioPlaying,
                            playlist: playlist,
                            onTap: {
                                let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name, cropStartTime: download.cropStartTime, cropEndTime: download.cropEndTime)
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
                                let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name, cropStartTime: download.cropStartTime, cropEndTime: download.cropEndTime)
                                audioPlayer.addToQueue(track)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
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
                .environment(\.editMode, .constant(.active))
                .scrollIndicators(.visible)
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: currentPlayingTrackID != nil ? 65 : 0)
                }
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
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.emberLight)
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
            currentPlayingTrackID = audioPlayer.currentTrack?.id
            isAudioPlaying = audioPlayer.isPlaying
            updateTotalDuration()
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
        
        Task {
            var total: TimeInterval = 0
            for url in trackURLs {
                let asset = AVAsset(url: url)
                if let duration = try? await asset.load(.duration) {
                    let seconds = duration.seconds
                    if seconds.isFinite {
                        total += seconds
                    }
                }
            }
            
            await MainActor.run {
                totalDuration = total
            }
        }
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
                ZStack {
                    AsyncThumbnailView(
                        thumbnailPath: download.resolvedThumbnailPath,
                        size: 48,
                        cornerRadius: 10
                    )
                    
                    // Pause icon overlay while this track is playing
                    if isCurrentlyPlaying && isPlaying {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.4))
                            .frame(width: 48, height: 48)
                        Image(systemName: "pause.fill")
                            .foregroundColor(Theme.bone)
                            .font(.system(size: 14))
                    }
                }
                .frame(width: 48, height: 48)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(download.name)
                        .font(Theme.body(15, weight: isCurrentlyPlaying ? .bold : .medium))
                        .foregroundColor(isCurrentlyPlaying ? Theme.emberLight : Theme.bone)
                        .lineLimit(1)
                    
                    SourceChip(source: download.source)
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
            
            // Animated EQ bars while this track is playing
            if isCurrentlyPlaying && isPlaying {
                EQIndicator()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .surfaceCard()
        .swipeToQueue {
            onQueue()
        }
    }
}

struct PlaylistActionButtons: View {
    let tracks: [Download]
    let playlistName: String
    let audioPlayer: AudioPlayerManager
    
    @State private var playConfirmPending = false
    @State private var shuffleConfirmPending = false
    @State private var playTimer: Timer?
    @State private var shuffleTimer: Timer?
    @State private var queuedPlayTracks: [Track] = []
    @State private var queuedShuffleTracks: [Track] = []
    
    private func makeTracks(shuffle: Bool) -> [Track] {
        let mapped = tracks.map { download in
            Track(
                id: download.id,
                name: download.name,
                url: download.url,
                folderName: playlistName,
                cropStartTime: download.cropStartTime,
                cropEndTime: download.cropEndTime
            )
        }
        return shuffle ? mapped.shuffled() : mapped
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // PLAY / PLAY NOW button
            Button {
                if playConfirmPending {
                    // Second tap — inject at front and play immediately
                    playTimer?.invalidate()
                    playTimer = nil
                    audioPlayer.injectAtFrontOfQueue(queuedPlayTracks)
                    playConfirmPending = false
                    queuedPlayTracks = []
                } else {
                    // First tap — queue the playlist
                    let t = makeTracks(shuffle: false)
                    queuedPlayTracks = t
                    audioPlayer.queuePlaylist(t, shuffle: false)
                    playConfirmPending = true
                    
                    // Reset shuffle state if active
                    if shuffleConfirmPending {
                        shuffleTimer?.invalidate()
                        shuffleTimer = nil
                        shuffleConfirmPending = false
                        queuedShuffleTracks = []
                    }
                    
                    // 2-second timeout
                    playTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        playConfirmPending = false
                        queuedPlayTracks = []
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: playConfirmPending ? "play.circle.fill" : "play.fill")
                    Text(playConfirmPending ? "Play now?" : "Play")
                }
                .font(Theme.body(15, weight: playConfirmPending ? .bold : .semibold))
                .foregroundColor(playConfirmPending ? Theme.ink : Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(
                        playConfirmPending
                            ? AnyShapeStyle(Theme.emberLight)
                            : AnyShapeStyle(Theme.emberGradient)
                    )
                )
                .animation(.easeInOut(duration: 0.15), value: playConfirmPending)
            }
            .buttonStyle(.plain)
            
            // SHUFFLE / SHUFFLE NOW button
            Button {
                if shuffleConfirmPending {
                    // Second tap — inject at front and play immediately
                    shuffleTimer?.invalidate()
                    shuffleTimer = nil
                    audioPlayer.injectAtFrontOfQueue(queuedShuffleTracks)
                    shuffleConfirmPending = false
                    queuedShuffleTracks = []
                } else {
                    // First tap — queue the shuffled playlist
                    let t = makeTracks(shuffle: true)
                    queuedShuffleTracks = t
                    audioPlayer.queuePlaylist(t, shuffle: false) // already shuffled
                    shuffleConfirmPending = true
                    
                    // Reset play state if active
                    if playConfirmPending {
                        playTimer?.invalidate()
                        playTimer = nil
                        playConfirmPending = false
                        queuedPlayTracks = []
                    }
                    
                    // 2-second timeout
                    shuffleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
                        shuffleConfirmPending = false
                        queuedShuffleTracks = []
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: shuffleConfirmPending ? "shuffle.circle.fill" : "shuffle")
                    Text(shuffleConfirmPending ? "Shuffle now?" : "Shuffle")
                }
                .font(Theme.body(15, weight: shuffleConfirmPending ? .bold : .semibold))
                .foregroundColor(Theme.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(
                        shuffleConfirmPending
                            ? AnyShapeStyle(Theme.emberLight)
                            : AnyShapeStyle(Theme.mintGradient)
                    )
                )
                .animation(.easeInOut(duration: 0.15), value: shuffleConfirmPending)
            }
            .buttonStyle(.plain)
        }
        .onDisappear {
            playTimer?.invalidate()
            shuffleTimer?.invalidate()
        }
    }
}
