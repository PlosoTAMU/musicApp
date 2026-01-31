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
                            ZStack {
                                if let thumbPath = download.resolvedThumbnailPath,
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

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var showAddSongs = false
    @State private var totalDuration: TimeInterval = 0
    
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

struct PlaylistSongRow: View {
    let download: Download
    @ObservedObject var audioPlayer: AudioPlayerManager
    let playlist: Playlist
    let onTap: () -> Void
    
    private var isCurrentlyPlaying: Bool {
        audioPlayer.currentTrack?.id == download.id
    }
    
    var body: some View {
        HStack(spacing: 12) {
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
                    .fontWeight(isCurrentlyPlaying ? .bold : .regular)
                    .italic(isCurrentlyPlaying)
                    .lineLimit(1)
                
                Spacer()
                
                if isCurrentlyPlaying && audioPlayer.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.blue)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black)
        .swipeToQueue {  // ✨ USE THE MODIFIER HERE
            let track = Track(id: download.id, name: download.name, url: download.url, folderName: playlist.name)
            audioPlayer.addToQueue(track)
        }
    }
}