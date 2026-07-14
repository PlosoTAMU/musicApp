import SwiftUI

struct DownloadsView: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    // Plain reference, not @ObservedObject: this view and its rows never need
    // to react to currentTime/duration (ticking every 0.5s during playback),
    // only to currentTrack/isPlaying — mirrored below via onReceive instead
    // of subscribing to the whole object's combined objectWillChange.
    let audioPlayer: AudioPlayerManager
    @ObservedObject var syncManager: SyncSessionManager
    @Binding var showFolderPicker: Bool
    @Binding var showYouTubeDownload: Bool
    @State private var showAddToPlaylist: Download?
    @State private var showHomeSync = false
    @State private var searchText = ""
    @State private var hasCurrentTrack = false
    @State private var hasActiveDownload = false
    @State private var currentTrack: Track?
    @State private var isPlaying = false
    
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
            ZStack {
                AppBackground()
                
                VStack(spacing: 0) {
                    // Always-visible search bar
                    ThemedSearchField(placeholder: "Search downloads", text: $searchText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    
                    List {
                        ForEach(filteredDownloads) { download in
                            DownloadRow(
                                download: download,
                                audioPlayer: audioPlayer,
                                isCurrentlyPlaying: currentTrack?.id == download.id,
                                isEnginePlaying: isPlaying,
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
                                },
                                onRename: { newName in
                                    downloadManager.renameDownload(download, newName: newName)
                                    // Force refresh to show new name immediately
                                    downloadManager.objectWillChange.send()
                                },
                                onRedownload: {
                                    downloadManager.redownload(download) {
                                        // Old song is being deleted, update UI if needed
                                        if audioPlayer.currentTrack?.id == download.id {
                                            audioPlayer.stop()
                                        }
                                        playlistManager.removeFromAllPlaylists(download.id)
                                    }
                                }
                            )
                            .opacity(download.pendingDeletion ? 0.55 : 1.0)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.visible)
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showHomeSync = true
                    } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(CircleControlButtonStyle(diameter: 32, tint: Theme.emberLight))
                }
            }
            .sheet(isPresented: $showHomeSync) {
                HomeSyncSheet(manager: syncManager)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: hasCurrentTrack ? (hasActiveDownload ? 130 : 65) : (hasActiveDownload ? 65 : 0))
            }
            .onReceive(audioPlayer.$currentTrack) { track in
                hasCurrentTrack = track != nil
                currentTrack = track
            }
            .onReceive(audioPlayer.$isPlaying) { playing in
                isPlaying = playing
            }
            .onReceive(downloadManager.$activeDownloads) { active in
                hasActiveDownload = !active.isEmpty
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Downloads")
                            .font(Theme.title(17))
                            .foregroundColor(Theme.bone)
                        Text("\(downloadManager.downloads.filter { !$0.pendingDeletion }.count) songs")
                            .font(Theme.caption(11))
                            .foregroundColor(Theme.boneDim)
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showYouTubeDownload = true
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.emberLight)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showFolderPicker = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.emberLight)
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
    // Plain reference — used only for method calls (play/pause/etc.) in
    // action closures below. Rendering state comes from the parent's
    // mirrored isCurrentlyPlaying/isEnginePlaying, not observed here.
    let audioPlayer: AudioPlayerManager
    let isCurrentlyPlaying: Bool
    let isEnginePlaying: Bool
    let onAddToPlaylist: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onRedownload: () -> Void

    @State private var showRenameAlert = false
    @State private var newName: String = ""
    @State private var showSongInfo = false
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    AsyncThumbnailView(
                        thumbnailPath: download.resolvedThumbnailPath,
                        size: 48,
                        cornerRadius: 10,
                        grayscale: download.pendingDeletion
                    )
                    
                    // Pause icon overlay while this track is playing
                    if isCurrentlyPlaying && isEnginePlaying {
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
                        .foregroundColor(
                            download.pendingDeletion
                                ? Theme.boneFaint
                                : (isCurrentlyPlaying ? Theme.emberLight : Theme.bone)
                        )
                        .lineLimit(1)
                    
                    if download.pendingDeletion {
                        Text("Tap to undo (5s)")
                            .font(Theme.caption(10, weight: .semibold))
                            .foregroundColor(Theme.emberLight)
                    } else {
                        SourceChip(source: download.source)
                    }
                }
                
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap()
            }
            .contextMenu {
                Button {
                    showSongInfo = true
                } label: {
                    Label("Song Info", systemImage: "info.circle")
                }
                
                Button {
                    newName = download.name
                    showRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                
                if download.originalURL != nil {
                    Button {
                        onRedownload()
                    } label: {
                        Label("Redownload", systemImage: "arrow.clockwise")
                    }
                }
            }
            
            // Animated EQ bars while this track is playing
            if isCurrentlyPlaying && isEnginePlaying {
                EQIndicator()
            }
            
            if !download.pendingDeletion {
                Button(action: onAddToPlaylist) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(Theme.emberLight)
                }
                .buttonStyle(.plain)
            }
            
            Button(action: onDelete) {
                Image(systemName: download.pendingDeletion ? "arrow.uturn.backward.circle.fill" : "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(download.pendingDeletion ? Theme.emberLight : Theme.danger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surfaceCard()
        .swipeToQueue {
            let folderName = folderName(for: download.source)
            let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName, cropStartTime: download.cropStartTime, cropEndTime: download.cropEndTime)
            audioPlayer.addToQueue(track)
        }
        .themedTextPrompt(
            "Rename Song",
            message: "Enter a new name for this song",
            placeholder: "Song name",
            text: $newName,
            isPresented: $showRenameAlert,
            confirmLabel: "Rename"
        ) {
            onRename(newName)
        }
        .sheet(isPresented: $showSongInfo) {
            SongInfoSheet(download: download)
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
            let track = Track(id: download.id, name: download.name, url: download.url, folderName: folderName, cropStartTime: download.cropStartTime, cropEndTime: download.cropEndTime)
            audioPlayer.play(track)
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

// MARK: - Song Info Sheet

struct SongInfoSheet: View {
    let download: Download
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                
                List {
                    Section(header: SectionEyebrow("Display")) {
                        InfoRow(label: "Title", value: download.name)
                        InfoRow(label: "Source", value: download.source.rawValue.capitalized)
                    }
                    .listRowBackground(Theme.smoke)
                    
                    if download.source == .spotify {
                        Section(header: SectionEyebrow("Spotify")) {
                            InfoRow(label: "Original URL", value: download.originalURL ?? "—")
                            InfoRow(label: "Spotify Title", value: download.spotifyTitle ?? "—")
                            InfoRow(label: "YouTube Search Query", value: download.youtubeSearchQuery ?? "—")
                        }
                        .listRowBackground(Theme.smoke)
                        Section(header: SectionEyebrow("YouTube")) {
                            InfoRow(label: "YouTube URL", value: download.youtubeURL ?? "—")
                            InfoRow(label: "YouTube Video ID", value: download.videoID ?? "—")
                        }
                        .listRowBackground(Theme.smoke)
                    } else {
                        Section(header: SectionEyebrow("YouTube")) {
                            InfoRow(label: "URL", value: download.originalURL ?? download.youtubeURL ?? "—")
                            InfoRow(label: "Video ID", value: download.videoID ?? "—")
                        }
                        .listRowBackground(Theme.smoke)
                    }
                    
                    Section(header: SectionEyebrow("File")) {
                        InfoRow(label: "Filename", value: download.url.lastPathComponent)
                        InfoRow(label: "File Path", value: download.url.path)
                    }
                    .listRowBackground(Theme.smoke)
                    
                    if download.cropStartTime != nil || download.cropEndTime != nil {
                        Section(header: SectionEyebrow("Crop")) {
                            InfoRow(label: "Start", value: download.cropStartTime.map { String(format: "%.2fs", $0) } ?? "—")
                            InfoRow(label: "End", value: download.cropEndTime.map { String(format: "%.2fs", $0) } ?? "—")
                        }
                        .listRowBackground(Theme.smoke)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Song Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.caption(11))
                .foregroundColor(Theme.boneDim)
            Text(value)
                .font(Theme.body(13))
                .foregroundColor(Theme.bone)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
