import SwiftUI

struct QueueView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Mode indicator
                HStack {
                    Image(systemName: audioPlayer.isPlaylistMode ? "music.note.list" : "music.note")
                        .foregroundColor(.blue)
                    Text(audioPlayer.isPlaylistMode ? "Playing from Playlist" : "Playing from Queue")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.gray.opacity(0.1))
                
                if audioPlayer.queue.isEmpty && !audioPlayer.isPlaylistMode {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("Queue is empty")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Swipe right on any song to add it to the queue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    List {
                        // Show current track
                        if let currentTrack = audioPlayer.currentTrack {
                            Section(header: Text("Now Playing")) {
                                QueueTrackRow(
                                    track: currentTrack,
                                    downloadManager: downloadManager,
                                    isPlaying: true,
                                    audioPlayer: audioPlayer
                                )
                            }
                        }
                        
                        // Show queue or playlist
                        if audioPlayer.isPlaylistMode {
                            Section(header: Text("Up Next from Playlist")) {
                                ForEach(Array(audioPlayer.upNextTracks.enumerated()), id: \.element.id) { index, track in
                                    QueueTrackRow(
                                        track: track,
                                        downloadManager: downloadManager,
                                        isPlaying: false,
                                        audioPlayer: audioPlayer
                                    )
                                }
                            }
                        } else {
                            Section(header: Text("Up Next")) {
                                ForEach(audioPlayer.queue) { track in
                                    QueueTrackRow(
                                        track: track,
                                        downloadManager: downloadManager,
                                        isPlaying: false,
                                        audioPlayer: audioPlayer
                                    )
                                }
                                .onMove { source, destination in
                                    audioPlayer.moveInQueue(from: source, to: destination)
                                }
                                .onDelete { offsets in
                                    audioPlayer.removeFromQueue(at: offsets)
                                }
                            }
                        }
                    }
                    .environment(\.editMode, audioPlayer.isPlaylistMode ? .constant(.inactive) : .constant(.active))
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                if !audioPlayer.queue.isEmpty && !audioPlayer.isPlaylistMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            audioPlayer.clearQueue()
                        } label: {
                            Text("Clear")
                                .foregroundColor(.red)
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
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            ZStack {
                if let download = downloadManager.getDownload(byID: track.id),
                   let thumbPath = download.thumbnailPath,
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
                                .font(.caption)
                                .foregroundColor(.gray)
                        )
                }
                
                if isPlaying && audioPlayer.isPlaying {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.4))
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 14))
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.body)
                    .foregroundColor(isPlaying ? .blue : .primary)
                    .lineLimit(1)
                
                Text(track.folderName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isPlaying {
                audioPlayer.playFromQueue(track)
            }
        }
    }
}