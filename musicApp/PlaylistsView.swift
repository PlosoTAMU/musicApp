import SwiftUI
import AVFoundation

struct PlaylistsView: View {
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    var audioPlayer: AudioPlayerManager
    @State private var showCreatePlaylist = false
    @State private var refreshID = UUID()
    @State private var cachedDurations: [UUID: TimeInterval] = [:]
    @State private var hasCurrentTrack = false
    @State private var renamingPlaylist: Playlist? = nil
    @State private var renameText: String = ""
    
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                
                Group {
                    if playlistManager.playlists.isEmpty {
                        EmptyStateView(
                            icon: "music.note.list",
                            title: "No playlists yet",
                            message: "Tap + to create your first playlist from your downloaded songs."
                        )
                    } else {
                        List {
                            ForEach(playlistManager.playlists) { playlist in
                                NavigationLink {
                                    PlaylistDetailView(
                                        playlist: playlist,
                                        playlistManager: playlistManager,
                                        downloadManager: downloadManager,
                                        audioPlayer: audioPlayer
                                    )
                                } label: {
                                    PlaylistCardLabel(
                                        playlist: playlist,
                                        coverThumbnailPath: coverThumbnailPath(for: playlist),
                                        duration: cachedDurations[playlist.id] ?? 0
                                    )
                                }
                                .listRowInsets(EdgeInsets(top: 9, leading: 28, bottom: 9, trailing: 24))
                                .listRowBackground(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Theme.smoke)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .strokeBorder(Theme.seam, lineWidth: 1)
                                        )
                                        .padding(.vertical, 4)
                                        .padding(.horizontal, 14)
                                )
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    Button {
                                        renameText = playlist.name
                                        renamingPlaylist = playlist
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        playlistManager.deletePlaylist(playlist)
                                        refreshID = UUID()
                                        computeDurationsAsync()
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .onDelete(perform: deletePlaylists)
                        }
                        .id(refreshID)
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.visible)
                    }
                }
            }
            .navigationTitle("Playlists")
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: hasCurrentTrack ? 65 : 0)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreatePlaylist = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.emberLight)
                    }
                }
            }
            .onAppear {
                hasCurrentTrack = audioPlayer.currentTrack != nil
                refreshID = UUID()
                computeDurationsAsync()
            }
            .onReceive(audioPlayer.$currentTrack) { track in
                hasCurrentTrack = track != nil
            }
            .alert("Rename Playlist", isPresented: Binding(
                get: { renamingPlaylist != nil },
                set: { if !$0 { renamingPlaylist = nil } }
            )) {
                TextField("Playlist name", text: $renameText)
                Button("Rename") {
                    if let playlist = renamingPlaylist {
                        playlistManager.renamePlaylist(playlist, newName: renameText)
                        refreshID = UUID()
                    }
                    renamingPlaylist = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingPlaylist = nil
                }
            }
        }
        .sheet(isPresented: $showCreatePlaylist) {
            CreatePlaylistSheet(
                playlistManager: playlistManager,
                downloadManager: downloadManager,
                onDismiss: { 
                    showCreatePlaylist = false
                    refreshID = UUID()
                    computeDurationsAsync()
                }
            )
        }
    }
    
    /// First track's artwork doubles as the playlist cover.
    private func coverThumbnailPath(for playlist: Playlist) -> String? {
        for trackID in playlist.trackIDs {
            if let path = downloadManager.getDownload(byID: trackID)?.resolvedThumbnailPath {
                return path
            }
        }
        return nil
    }
    
    /// Compute all playlist durations off the main thread
    private func computeDurationsAsync() {
        let playlists = playlistManager.playlists
        let dm = downloadManager
        
        Task {
            var durations: [UUID: TimeInterval] = [:]
            
            for playlist in playlists {
                var total: TimeInterval = 0
                for trackID in playlist.trackIDs {
                    if let download = dm.getDownload(byID: trackID) {
                        let asset = AVAsset(url: download.url)
                        if let duration = try? await asset.load(.duration) {
                            let seconds = duration.seconds
                            if seconds.isFinite {
                                total += seconds
                            }
                        }
                    }
                }
                durations[playlist.id] = total
            }
            
            await MainActor.run {
                cachedDurations = durations
            }
        }
    }
    
    func deletePlaylists(at offsets: IndexSet) {
        for index in offsets {
            playlistManager.deletePlaylist(playlistManager.playlists[index])
        }
        refreshID = UUID()
        computeDurationsAsync()
    }
}

// MARK: - Playlist card label

private struct PlaylistCardLabel: View {
    let playlist: Playlist
    let coverThumbnailPath: String?
    let duration: TimeInterval
    
    var body: some View {
        HStack(spacing: 14) {
            AsyncThumbnailView(
                thumbnailPath: coverThumbnailPath,
                size: 54,
                cornerRadius: 12
            )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(Theme.title(16, weight: .semibold))
                    .foregroundColor(Theme.bone)
                    .lineLimit(1)
                
                Text("\(playlist.trackIDs.count) songs  •  \(formatDuration(duration))")
                    .font(Theme.caption(11))
                    .foregroundColor(Theme.boneDim)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
