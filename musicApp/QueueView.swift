import SwiftUI

struct QueueView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                
                VStack(spacing: 0) {
                    // Status strip — what the player is currently drawing from
                    if audioPlayer.currentTrack != nil {
                        HStack(spacing: 8) {
                            Image(systemName: audioPlayer.isPlaylistMode ? "music.note.list" : "line.3.horizontal")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Theme.emberLight)
                            
                            Text(audioPlayer.isPlaylistMode ? "PLAYING FROM PLAYLIST" : "PLAYING FROM QUEUE")
                                .font(Theme.eyebrowFont)
                                .tracking(1.5)
                                .foregroundColor(Theme.boneDim)
                            
                            Spacer()
                            
                            if audioPlayer.isPlaylistMode {
                                Text("\(audioPlayer.upNextTracks.count + 1) songs")
                                    .font(Theme.caption(11))
                                    .foregroundColor(Theme.boneFaint)
                            } else {
                                Text("\(audioPlayer.previousQueue.count + 1 + audioPlayer.queue.count) songs")
                                    .font(Theme.caption(11))
                                    .foregroundColor(Theme.boneFaint)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .surfaceCard(corner: 12)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                    }
                    
                    if audioPlayer.currentTrack == nil && audioPlayer.previousQueue.isEmpty {
                        VStack {
                            Spacer()
                            EmptyStateView(
                                icon: "music.note.list",
                                title: "No song playing",
                                message: "Play a song or swipe right on any track to add it to the queue"
                            )
                            Spacer()
                        }
                    } else if audioPlayer.currentTrack == nil && !audioPlayer.previousQueue.isEmpty {
                        // Show only previous songs when playback has ended
                        List {
                            Section(header: SectionEyebrow("Previously Played")) {
                                ForEach(audioPlayer.previousQueue) { track in
                                    QueueTrackRow(
                                        track: track,
                                        downloadManager: downloadManager,
                                        isPlaying: false,
                                        isPrevious: true,
                                        audioPlayer: audioPlayer
                                    )
                                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.visible)
                    } else {
                        List {
                            // Previous songs (most recent at bottom)
                            if !audioPlayer.previousQueue.isEmpty {
                                Section(header: SectionEyebrow("Previous")) {
                                    ForEach(audioPlayer.previousQueue) { track in
                                        QueueTrackRow(
                                            track: track,
                                            downloadManager: downloadManager,
                                            isPlaying: false,
                                            isPrevious: true,
                                            audioPlayer: audioPlayer
                                        )
                                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                    }
                                }
                            }
                            
                            // Current track
                            Section(header: HStack {
                                SectionEyebrow("Now Playing")
                                if audioPlayer.isPlaying {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Theme.emberLight)
                                            .frame(width: 6, height: 6)
                                        Text("LIVE")
                                            .font(Theme.eyebrowFont)
                                            .tracking(1.5)
                                            .foregroundColor(Theme.emberLight)
                                    }
                                }
                            }) {
                                QueueTrackRow(
                                    track: audioPlayer.currentTrack!,
                                    downloadManager: downloadManager,
                                    isPlaying: true,
                                    isPrevious: false,
                                    audioPlayer: audioPlayer
                                )
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                            
                            // Up next
                            if audioPlayer.isPlaylistMode {
                                // Show queued songs first (user-added)
                                if !audioPlayer.queue.isEmpty {
                                    Section(header: SectionEyebrow("Up Next")) {
                                        ForEach(audioPlayer.queue) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer
                                            )
                                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                        }
                                        .onMove { source, destination in
                                            audioPlayer.moveInQueue(from: source, to: destination)
                                        }
                                        .onDelete { offsets in
                                            audioPlayer.removeFromQueue(at: offsets)
                                        }
                                    }
                                }
                                
                                // Then show remaining playlist tracks
                                let playlistUpNext = audioPlayer.playlistUpNextTracks
                                if !playlistUpNext.isEmpty {
                                    Section(header: SectionEyebrow("Up Next from Playlist")) {
                                        ForEach(playlistUpNext) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer
                                            )
                                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                        }
                                    }
                                }
                            } else {
                                if !audioPlayer.queue.isEmpty {
                                    Section(header: SectionEyebrow("Up Next")) {
                                        ForEach(audioPlayer.queue) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer
                                            )
                                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                        }
                                        .onMove { source, destination in
                                            audioPlayer.moveInQueue(from: source, to: destination)
                                        }
                                        .onDelete { offsets in
                                            audioPlayer.removeFromQueue(at: offsets)
                                        }
                                    }
                                } else {
                                    Section {
                                        VStack(spacing: 8) {
                                            Image(systemName: "arrow.right.circle")
                                                .font(.system(size: 24, weight: .medium))
                                                .foregroundColor(Theme.mint.opacity(0.6))
                                            Text("Queue is empty")
                                                .font(Theme.body(14, weight: .semibold))
                                                .foregroundColor(Theme.boneDim)
                                            Text("Swipe right on songs to add them")
                                                .font(Theme.caption(11))
                                                .foregroundColor(Theme.boneFaint)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.editMode, .constant(.active))
                        .scrollIndicators(.visible)
                        .safeAreaInset(edge: .bottom) {
                            Color.clear.frame(height: audioPlayer.currentTrack != nil ? 65 : 0)
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                // Show "Clear All" if there are ANY upcoming tracks (queue or playlist)
                if !audioPlayer.queue.isEmpty || !audioPlayer.previousQueue.isEmpty || audioPlayer.isPlaylistMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            audioPlayer.clearQueueAndExitPlaylist()
                        } label: {
                            Text("Clear All")
                                .font(Theme.body(15, weight: .semibold))
                                .foregroundColor(Theme.danger)
                        }
                    }
                }
            }
        }
    }
}


struct QueueTrackRow: View {
    let track: Track
    @ObservedObject var downloadManager: DownloadManager
    let isPlaying: Bool
    let isPrevious: Bool
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    @State private var showRenameAlert = false
    @State private var newName: String = ""
    
    private var download: Download? {
        downloadManager.getDownload(byID: track.id)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    AsyncThumbnailView(
                        thumbnailPath: download?.resolvedThumbnailPath,
                        size: 46,
                        cornerRadius: 10
                    )
                    .opacity(isPrevious ? 0.55 : 1.0)
                    
                    // Pause glyph over the artwork while this row is playing
                    if isPlaying && audioPlayer.isPlaying {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.45))
                        Image(systemName: "pause.fill")
                            .foregroundColor(Theme.bone)
                            .font(.system(size: 14, weight: .bold))
                    }
                }
                .frame(width: 46, height: 46)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(Theme.body(15, weight: isPlaying ? .bold : .medium))
                        .foregroundColor(isPlaying ? Theme.emberLight : (isPrevious ? Theme.boneDim : Theme.bone))
                        .lineLimit(1)
                    
                    Text(track.folderName)
                        .font(Theme.caption(11))
                        .foregroundColor(Theme.boneFaint)
                        .lineLimit(1)
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isPlaying {
                    if isPrevious {
                        audioPlayer.play(track)
                    } else {
                        audioPlayer.playFromQueue(track)
                    }
                } else {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                }
            }
            .contextMenu {
                if let download = download {
                    Button {
                        newName = download.name
                        showRenameAlert = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    
                    if let videoID = download.videoID, !videoID.isEmpty {
                        Button {
                            redownload(download: download)
                        } label: {
                            Label("Redownload", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .alert("Rename Song", isPresented: $showRenameAlert) {
                TextField("Song name", text: $newName)
                Button("Cancel", role: .cancel) { }
                Button("Rename") {
                    if let download = download {
                        downloadManager.renameDownload(download, newName: newName)
                    }
                }
            } message: {
                Text("Enter a new name for this song")
            }
            
            // Live EQ beside the playing track
            if isPlaying && audioPlayer.isPlaying {
                EQIndicator()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .surfaceCard()
    }
    
    private func redownload(download: Download) {
        guard let videoID = download.videoID else { return }
        let url: String
        
        switch download.source {
        case .youtube:
            url = "https://www.youtube.com/watch?v=\(videoID)"
        case .spotify:
            url = "https://open.spotify.com/track/\(videoID)"
        case .folder:
            return // Can't redownload folder imports
        }
        
        downloadManager.startBackgroundDownload(
            url: url,
            videoID: videoID,
            source: download.source,
            title: "Redownloading..."
        )
    }
}
