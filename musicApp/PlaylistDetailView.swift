import SwiftUI
import AVFoundation

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showAddSongs = false
    @State private var editMode: EditMode = .active
    @State private var totalDuration: TimeInterval = 0
    
    var tracks: [Download] {
        playlistManager.getTracks(for: playlist, from: downloadManager)
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
                ForEach(tracks) { download in
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
                        audioPlayer.play(track)
                    }
                }
                .onMove { source, destination in
                    playlistManager.moveTrack(in: playlist.id, from: source, to: destination)
                }
                .onDelete { offsets in
                    for index in offsets {
                        let download = tracks[index]
                        playlistManager.removeFromPlaylist(playlist.id, downloadID: download.id)
                    }
                    updateTotalDuration()
                }
            }
            .environment(\.editMode, $editMode)
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
                downloadManager: downloadManager
            )
        }
        .onAppear {
            updateTotalDuration()
        }
        .onChange(of: tracks.count) { _ in
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
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Select Songs Sheet for adding to playlist
struct SelectSongsSheet: View {
    let playlistID: UUID
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
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
                    }
                }
            }
        }
    }
}