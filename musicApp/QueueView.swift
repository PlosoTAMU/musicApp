import SwiftUI

struct QueueView: View {
    // Plain reference, not @ObservedObject: this view needs to react to
    // currentTrack/queue/previousQueue/playlist-mode changes, but NOT to
    // currentTime/duration (which tick every 0.5s during playback) —
    // @ObservedObject's objectWillChange fires on ANY @Published change on
    // the object, so it can't distinguish between the two. Mirroring just
    // the fields this view actually needs (below) via onReceive subscribes
    // to those specific Combine publishers instead of the whole-object signal.
    let audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    /// Only for the shared-queue ghost list — same non-observed treatment as
    /// `audioPlayer` above; the one publisher this view needs is mirrored below.
    let syncManager: SyncSessionManager

    @State private var currentTrack: Track?
    @State private var isPlaying = false
    @State private var isPlaylistMode = false
    @State private var queue: [Track] = []
    @State private var previousQueue: [Track] = []
    @State private var currentPlaylist: [Track] = []
    @State private var currentIndex: Int = 0
    /// Entries in the SHARED queue that don't resolve to a file on this device.
    /// The engine has always published these; nothing rendered them, so those
    /// tracks silently vanished from Up Next here while every other device
    /// showed them (sync-audit-4 M13). Desktop draws a "not here yet" row.
    @State private var ghostQueue: [TrackRef] = []

    /// True while another device owns playback and this phone is a remote.
    @State private var isRemote = false
    /// The owner's published playback state (mirrored for remote-mode UI).
    @State private var mirror: PlaybackState?
    /// The owner's current track resolved against this phone's library; nil
    /// when the track hasn't replicated here yet (a ghost).
    @State private var mirrorTrack: Track?

    /// Effective "now playing" track: the owner's track while remote,
    /// this phone's local track otherwise.
    private var effCurrentTrack: Track? { isRemote ? mirrorTrack : currentTrack }
    /// Non-nil in remote mode even when the track is a ghost — the name still
    /// comes from the owner's mirror, only the resolved file may be missing.
    private var effCurrentName: String? { isRemote ? mirror?.track?.name : currentTrack?.name }
    private var effIsPlaying: Bool { isRemote ? (mirror?.isPlaying ?? false) : isPlaying }
    /// History is owner-local; a follower's own previousQueue is meaningless.
    private var effPrevious: [Track] { isRemote ? [] : previousQueue }
    private var effPlaylistMode: Bool { isRemote ? false : isPlaylistMode }

    /// Remote-mode tap on the Now Playing row: send the toggle to the owner.
    /// Never touches local audio — a local resume() here would claim the
    /// session and hijack playback (sync-audit-5 S4).
    private func toggleRemotePlayback() {
        if effIsPlaying { syncManager.engine.requestPause() }
        else { syncManager.engine.requestPlay() }
    }

    // Local mirrors of AudioPlayerManager's identically-named computed
    // properties, verbatim, so this view's rendering doesn't depend on an
    // unobserved live read of `audioPlayer` for its actual list content.
    private var upNextTracks: [Track] {
        if isPlaylistMode && !currentPlaylist.isEmpty {
            var upcoming: [Track] = []
            upcoming.append(contentsOf: queue)
            let nextIndex = currentIndex + 1
            if nextIndex < currentPlaylist.count {
                upcoming.append(contentsOf: currentPlaylist[nextIndex...])
            }
            return upcoming
        }
        return queue
    }

    private var playlistUpNextTracks: [Track] {
        guard isPlaylistMode, !currentPlaylist.isEmpty else { return [] }
        let nextIndex = currentIndex + 1
        if nextIndex < currentPlaylist.count {
            return Array(currentPlaylist[nextIndex...])
        }
        return []
    }

    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()

                VStack(spacing: 0) {
                    // Status strip — what the player is currently drawing from
                    if effCurrentName != nil {
                        HStack(spacing: 8) {
                            if isRemote {
                                Image(systemName: "laptopcomputer.and.iphone")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.emberLight)
                            } else {
                                Image(systemName: effPlaylistMode ? "music.note.list" : "line.3.horizontal")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.emberLight)
                            }

                            Text(isRemote ? "PLAYING ON ANOTHER DEVICE" : (effPlaylistMode ? "PLAYING FROM PLAYLIST" : "PLAYING FROM QUEUE"))
                                .font(Theme.eyebrowFont)
                                .tracking(1.5)
                                .foregroundColor(Theme.boneDim)

                            Spacer()

                            if effPlaylistMode {
                                Text("\(upNextTracks.count + 1) songs")
                                    .font(Theme.caption(11))
                                    .foregroundColor(Theme.boneFaint)
                            } else {
                                Text("\(effPrevious.count + 1 + queue.count) songs")
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

                    if effCurrentName == nil && effPrevious.isEmpty {
                        VStack {
                            Spacer()
                            EmptyStateView(
                                icon: "music.note.list",
                                title: "No song playing",
                                message: "Play a song or swipe right on any track to add it to the queue"
                            )
                            Spacer()
                        }
                    } else if effCurrentName == nil && !effPrevious.isEmpty {
                        // Show only previous songs when playback has ended
                        List {
                            Section(header: SectionEyebrow("Previously Played")) {
                                ForEach(effPrevious) { track in
                                    QueueTrackRow(
                                        track: track,
                                        downloadManager: downloadManager,
                                        isPlaying: false,
                                        isPrevious: true,
                                        audioPlayer: audioPlayer,
                                        isEnginePlaying: effIsPlaying
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
                            if !effPrevious.isEmpty {
                                Section(header: SectionEyebrow("Previous")) {
                                    ForEach(effPrevious) { track in
                                        QueueTrackRow(
                                            track: track,
                                            downloadManager: downloadManager,
                                            isPlaying: false,
                                            isPrevious: true,
                                            audioPlayer: audioPlayer,
                                            isEnginePlaying: effIsPlaying
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
                                if effIsPlaying {
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
                                if let effCurrentTrack {
                                    QueueTrackRow(
                                        track: effCurrentTrack,
                                        downloadManager: downloadManager,
                                        isPlaying: true,
                                        isPrevious: false,
                                        audioPlayer: audioPlayer,
                                        isEnginePlaying: effIsPlaying,
                                        onToggleCurrent: isRemote ? toggleRemotePlayback : nil
                                    )
                                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                } else if isRemote, let ref = mirror?.track {
                                    GhostQueueRow(ref: ref)
                                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                }
                            }

                            // Up next
                            if effPlaylistMode {
                                // Show queued songs first (user-added)
                                if !queue.isEmpty {
                                    Section(header: SectionEyebrow("Up Next")) {
                                        ForEach(queue) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer,
                                                isEnginePlaying: effIsPlaying
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
                                let playlistUpNext = playlistUpNextTracks
                                if !playlistUpNext.isEmpty {
                                    Section(header: SectionEyebrow("Up Next from Playlist")) {
                                        ForEach(playlistUpNext) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer,
                                                isEnginePlaying: effIsPlaying
                                            )
                                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                            .listRowBackground(Color.clear)
                                            .listRowSeparator(.hidden)
                                        }
                                    }
                                }
                            } else {
                                if !queue.isEmpty {
                                    Section(header: SectionEyebrow("Up Next")) {
                                        ForEach(queue) { track in
                                            QueueTrackRow(
                                                track: track,
                                                downloadManager: downloadManager,
                                                isPlaying: false,
                                                isPrevious: false,
                                                audioPlayer: audioPlayer,
                                                isEnginePlaying: effIsPlaying
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

                            // Shared-queue entries with no local file. Listed
                            // rather than dropped so the queue here matches what
                            // the other devices show (sync-audit-4 M13); the
                            // replicator pulls them in the background, and each
                            // moves into Up Next as its download lands.
                            if !ghostQueue.isEmpty {
                                Section(header: SectionEyebrow("Not On This Device Yet")) {
                                    ForEach(ghostQueue, id: \.id) { ref in
                                        GhostQueueRow(ref: ref)
                                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
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
                        // Animate only single-row add/remove (clean inserts).
                        // The track-advance case is intentionally NOT animated:
                        // it reshuffles three sections at once (now-playing →
                        // previous, up-next → now-playing), and animating that
                        // whole diff is what looked choppy. Instant is cleaner.
                        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: queue.count)
                        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: previousQueue.count)
                        .safeAreaInset(edge: .bottom) {
                            Color.clear.frame(height: (currentTrack != nil || isRemote) ? 65 : 0)
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                // Show "Clear All" if there are ANY upcoming tracks (queue or playlist)
                if !queue.isEmpty || !effPrevious.isEmpty || effPlaylistMode {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear All") {
                            audioPlayer.clearQueueAndExitPlaylist()
                        }
                        .buttonStyle(ChipButtonStyle(tint: Theme.danger))
                    }
                }
            }
        }
        .onAppear {
            currentTrack = audioPlayer.currentTrack
            isPlaying = audioPlayer.isPlaying
            isPlaylistMode = audioPlayer.isPlaylistMode
            queue = audioPlayer.queue
            previousQueue = audioPlayer.previousQueue
            currentPlaylist = audioPlayer.currentPlaylist
            currentIndex = audioPlayer.currentIndex
            isRemote = syncManager.engine.isRemoteControlled
        }
        .onReceive(syncManager.engine.$ghostQueue) { ghostQueue = $0 }
        .onReceive(syncManager.engine.$mirror) { mirror = $0 }
        .onReceive(syncManager.engine.$mirrorTrack) { mirrorTrack = $0 }
        // Deferred a turn: @Published emits in willSet, so a synchronous read of
        // isRemoteControlled here would still see the OLD role/remote and lag
        // one transition behind.
        .onReceive(syncManager.coordinator.$role) { _ in
            DispatchQueue.main.async { isRemote = syncManager.engine.isRemoteControlled }
        }
        .onReceive(syncManager.coordinator.$remote) { _ in
            DispatchQueue.main.async { isRemote = syncManager.engine.isRemoteControlled }
        }
        .onReceive(audioPlayer.$currentTrack) { currentTrack = $0 }
        .onReceive(audioPlayer.$isPlaying) { isPlaying = $0 }
        .onReceive(audioPlayer.$isPlaylistMode) { isPlaylistMode = $0 }
        .onReceive(audioPlayer.$queue) { queue = $0 }
        .onReceive(audioPlayer.$previousQueue) { previousQueue = $0 }
        .onReceive(audioPlayer.$currentPlaylist) { currentPlaylist = $0 }
        .onReceive(audioPlayer.$currentIndex) { currentIndex = $0 }
    }
}


/// A shared-queue entry with no file on this device. Read-only on purpose:
/// there's nothing to play, and removing it here would delete it from every
/// other device's queue too. Twin of desktop's `.ghost` row + "not here yet"
/// chip (ui.ts renderQueue).
struct GhostQueueRow: View {
    let ref: TrackRef

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.bone.opacity(0.06))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.boneFaint)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(ref.name)
                    .font(Theme.body(15, weight: .medium))
                    .foregroundColor(Theme.boneDim)
                    .lineLimit(1)

                Text("Not on this device yet")
                    .font(Theme.caption(11))
                    .foregroundColor(Theme.boneFaint)
                    .lineLimit(1)
            }

            Spacer()
        }
        .opacity(0.7)
    }
}

struct QueueTrackRow: View {
    let track: Track
    @ObservedObject var downloadManager: DownloadManager
    let isPlaying: Bool
    let isPrevious: Bool
    let audioPlayer: AudioPlayerManager
    /// Global engine playing/paused state — mirrored by the parent, not
    /// observed here (see QueueView's comment on why).
    let isEnginePlaying: Bool
    /// When set, the current row's tap toggles playback THROUGH this closure
    /// instead of calling audioPlayer.pause()/resume() directly — remote mode
    /// needs the tap routed to the owner rather than hijacking local audio.
    var onToggleCurrent: (() -> Void)? = nil

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
                        thumbnailPath: download?.artworkPath,
                        size: 46,
                        cornerRadius: 10
                    )
                    .opacity(isPrevious ? 0.55 : 1.0)

                    // Pause glyph over the artwork while this row is playing
                    if isPlaying && isEnginePlaying {
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
                    if let onToggleCurrent {
                        onToggleCurrent()
                    } else if isEnginePlaying {
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
            .themedTextPrompt(
                "Rename Song",
                message: "Enter a new name for this song",
                placeholder: "Song name",
                text: $newName,
                isPresented: $showRenameAlert,
                confirmLabel: "Rename"
            ) {
                if let download = download {
                    downloadManager.renameDownload(download, newName: newName)
                }
            }

            // Live EQ beside the playing track
            if isPlaying && isEnginePlaying {
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
