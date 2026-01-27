import SwiftUI

struct QueueView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if audioPlayer.currentTrack != nil {
                    HStack(spacing: 8) {
                        Image(systemName: audioPlayer.isPlaylistMode ? "music.note.list" : "line.3.horizontal")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text(audioPlayer.isPlaylistMode ? "Playing from Playlist" : "Playing from Queue")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if audioPlayer.isPlaylistMode {
                            Text("\(audioPlayer.upNextTracks.count + 1) songs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(audioPlayer.previousQueue.count + 1 + audioPlayer.queue.count) songs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.gray.opacity(0.1))
                }
                
                if audioPlayer.currentTrack == nil {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("No song playing")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Play a song or swipe right on any track to add it to the queue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    List {
                        // FIXED: Show previous songs
                        if !audioPlayer.previousQueue.isEmpty && !audioPlayer.isPlaylistMode {
                            Section(header: Text("Previous")) {
                                ForEach(audioPlayer.previousQueue.reversed()) { track in
                                    QueueTrackRow(
                                        track: track,
                                        downloadManager: downloadManager,
                                        isPlaying: false,
                                        isPrevious: true,
                                        audioPlayer: audioPlayer
                                    )
                                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                        
                        // Current track
                        Section(header: HStack {
                            Text("Now Playing")
                            Spacer()
                            if audioPlayer.isPlaying {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                    Text("Playing")
                                        .font(.caption2)
                                        .foregroundColor(.green)
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
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                        }
                        
                        // Up next
                        if audioPlayer.isPlaylistMode {
                            if !audioPlayer.upNextTracks.isEmpty {
                                Section(header: Text("Up Next from Playlist")) {
                                    ForEach(Array(audioPlayer.upNextTracks.enumerated()), id: \.element.id) { index, track in
                                        QueueTrackRow(
                                            track: track,
                                            downloadManager: downloadManager,
                                            isPlaying: false,
                                            isPrevious: false,
                                            audioPlayer: audioPlayer
                                        )
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                        .listRowBackground(Color.clear)
                                    }
                                }
                            }
                        } else {
                            if !audioPlayer.queue.isEmpty {
                                Section(header: Text("Up Next")) {
                                    ForEach(audioPlayer.queue) { track in
                                        QueueTrackRow(
                                            track: track,
                                            downloadManager: downloadManager,
                                            isPlaying: false,
                                            isPrevious: false,
                                            audioPlayer: audioPlayer
                                        )
                                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                        .listRowBackground(Color.clear)
                                    }
                                    .onMove { source, destination in
                                        audioPlayer.moveInQueue(from: source, to: destination)
                                    }
                                    .onDelete { offsets in
                                        audioPlayer.removeFromQueue(at: offsets)
                                    }
                                }
                                .listRowSeparator(.hidden)
                            } else {
                                Section {
                                    VStack(spacing: 8) {
                                        Image(systemName: "arrow.right.circle")
                                            .font(.title2)
                                            .foregroundColor(.blue.opacity(0.5))
                                        Text("Queue is empty")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Text("Swipe right on songs to add them")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 20)
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .environment(\.editMode, audioPlayer.queue.isEmpty ? .constant(.inactive) : .constant(.active))
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                if (!audioPlayer.queue.isEmpty || !audioPlayer.previousQueue.isEmpty) && !audioPlayer.isPlaylistMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            audioPlayer.clearQueue()
                        } label: {
                            Text("Clear All")
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
    let isPrevious: Bool
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let download = downloadManager.getDownload(byID: track.id),
                   let thumbPath = download.thumbnailPath,
                   let image = UIImage(contentsOfFile: thumbPath) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(isPrevious ? 0.6 : 1.0)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundColor(.gray)
                        )
                        .opacity(isPrevious ? 0.6 : 1.0)
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
                    .fontWeight(isPlaying ? .bold : .regular)
                    .italic(isPlaying)
                    .foregroundColor(isPlaying ? .blue : (isPrevious ? .secondary : .primary))
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
                if isPrevious {
                    // Tap on previous song - need to reconstruct queue
                    // This is complex, so just play it directly
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
    }
}