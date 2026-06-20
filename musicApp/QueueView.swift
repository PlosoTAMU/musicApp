import SwiftUI

// Role of a row in the unified queue list. Driving styling off a role (rather
// than which Section a row lives in) is what lets the whole queue be ONE ForEach
// — so advancing a track is a cheap style crossfade instead of a cross-section
// remove+insert.
enum QueueRole {
    case previous
    case current
    case upNextQueued    // user-queued, reorderable/removable
    case upNextPlaylist  // remaining playlist tracks, not reorderable
}

private struct QueueRowItem: Identifiable {
    let track: Track
    let role: QueueRole
    var id: UUID { track.id }
}

struct QueueView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager

    // The whole queue as ONE chronological, identity-stable array. Because the
    // play order never changes on advance (current → previous, upNext[0] →
    // current keeps the same sequence), the row ids stay in the same order and
    // SwiftUI only restyles two rows — no janky reshuffle.
    private var queueItems: [QueueRowItem] {
        var items: [QueueRowItem] = []
        items += audioPlayer.previousQueue.map { QueueRowItem(track: $0, role: .previous) }
        if let current = audioPlayer.currentTrack {
            items.append(QueueRowItem(track: current, role: .current))
        }
        items += audioPlayer.queue.map { QueueRowItem(track: $0, role: .upNextQueued) }
        if audioPlayer.isPlaylistMode {
            items += audioPlayer.playlistUpNextTracks.map { QueueRowItem(track: $0, role: .upNextPlaylist) }
        }
        // ForEach needs unique ids; drop any later duplicate (e.g. a queued song
        // that also sits in history) keeping the earliest in play order.
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private var songCount: Int {
        if audioPlayer.isPlaylistMode {
            return audioPlayer.upNextTracks.count + 1
        }
        return audioPlayer.previousQueue.count + (audioPlayer.currentTrack != nil ? 1 : 0) + audioPlayer.queue.count
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    if audioPlayer.currentTrack != nil {
                        statusStrip
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
                    } else {
                        queueList
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
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

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: audioPlayer.isPlaylistMode ? "music.note.list" : "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.emberLight)

            Text(audioPlayer.isPlaylistMode ? "PLAYING FROM PLAYLIST" : "PLAYING FROM QUEUE")
                .font(Theme.eyebrowFont)
                .tracking(1.5)
                .foregroundColor(Theme.boneDim)

            Spacer()

            Text("\(songCount) songs")
                .font(Theme.caption(11))
                .foregroundColor(Theme.boneFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .surfaceCard(corner: 12)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    // MARK: - Unified list

    private var queueList: some View {
        List {
            ForEach(queueItems) { item in
                QueueTrackRow(
                    track: item.track,
                    role: item.role,
                    downloadManager: downloadManager,
                    audioPlayer: audioPlayer
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .moveDisabled(item.role != .upNextQueued)
                .deleteDisabled(item.role != .upNextQueued)
            }
            .onMove(perform: moveRows)
            .onDelete(perform: deleteRows)

            // Inline hint when the user queue is empty (non-playlist mode).
            if !audioPlayer.isPlaylistMode && audioPlayer.queue.isEmpty && audioPlayer.currentTrack != nil {
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
                .moveDisabled(true)
                .deleteDisabled(true)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .scrollIndicators(.visible)
        // One spring on the ROW-ID ORDER: fires on insert / remove / reorder
        // (the cases that actually move rows) and animates them as true moves.
        // Advance doesn't change this order, so it stays still here and the role
        // crossfade (inside the row) handles it instead.
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: queueItems.map(\.id))
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: audioPlayer.currentTrack != nil ? 65 : 0)
        }
    }

    // MARK: - Reorder / delete mapping
    //
    // The ForEach is over the unified list, but moveInQueue/removeFromQueue work
    // on `audioPlayer.queue`. The queued rows are a contiguous block; subtract
    // the index of the first queued row to convert unified indices → queue indices.

    private func moveRows(from source: IndexSet, to destination: Int) {
        let items = queueItems
        guard let base = items.firstIndex(where: { $0.role == .upNextQueued }) else { return }
        let mappedSource = IndexSet(source.compactMap { $0 >= base ? $0 - base : nil })
        guard !mappedSource.isEmpty else { return }
        let mappedDest = max(0, destination - base)
        audioPlayer.moveInQueue(from: mappedSource, to: mappedDest)
    }

    private func deleteRows(at offsets: IndexSet) {
        let items = queueItems
        guard let base = items.firstIndex(where: { $0.role == .upNextQueued }) else { return }
        let mapped = IndexSet(offsets.compactMap { $0 >= base ? $0 - base : nil })
        guard !mapped.isEmpty else { return }
        audioPlayer.removeFromQueue(at: mapped)
    }
}


struct QueueTrackRow: View {
    let track: Track
    let role: QueueRole
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var audioPlayer: AudioPlayerManager

    @State private var showRenameAlert = false
    @State private var newName: String = ""

    private var isCurrent: Bool { role == .current }
    private var isPrevious: Bool { role == .previous }

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
                    if isCurrent && audioPlayer.isPlaying {
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
                        .font(Theme.body(15, weight: isCurrent ? .bold : .medium))
                        .foregroundColor(isCurrent ? Theme.emberLight : (isPrevious ? Theme.boneDim : Theme.bone))
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
                if isCurrent {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } else if isPrevious {
                    audioPlayer.play(track)
                } else {
                    audioPlayer.playFromQueue(track)
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
            if isCurrent && audioPlayer.isPlaying {
                EQIndicator()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .surfaceCard()
        // Crossfade styling when a row changes role (the advance case) and when
        // play/pause toggles — no layout move, just a smooth restyle.
        .animation(.easeInOut(duration: 0.32), value: role)
        .animation(.easeInOut(duration: 0.2), value: audioPlayer.isPlaying)
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
