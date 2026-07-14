import SwiftUI
import AVFoundation
import MediaPlayer
import Accelerate
import Combine

struct ContentView: View {
    @StateObject private var audioPlayer: AudioPlayerManager
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var playlistManager = PlaylistManager()
    @StateObject private var syncManager: SyncSessionManager
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    @State private var showNowPlaying = false
    // Now Playing slide position, owned here so the mini player can crossfade
    // with it (stay visible during the slide instead of vanishing instantly).
    @State private var nowPlayingOffset: CGFloat = UIScreen.main.bounds.height
    @State private var handlingDeepLink = false
    
    // For post-download playlist prompt
    @State private var playlistPromptDownload: Download? = nil
    
    @MainActor
    init() {
        // Theme the UIKit-backed chrome (nav bars + tab bar) before first render.
        Theme.applyChrome()

        // Sync needs the SAME player/download instances the UI observes, so all
        // three are built here and handed to their StateObjects together.
        let player = AudioPlayerManager()
        let downloads = DownloadManager()
        _audioPlayer = StateObject(wrappedValue: player)
        _downloadManager = StateObject(wrappedValue: downloads)
        _syncManager = StateObject(wrappedValue: SyncSessionManager(
            player: player,
            library: {
                // "YouTube Downloads" folderName skips Track's bookmark work —
                // these are app-documents files, resolvable by URL directly.
                downloads.downloads.map {
                    Track(id: $0.id, name: $0.name, url: $0.url,
                          folderName: "YouTube Downloads",
                          cropStartTime: $0.cropStartTime, cropEndTime: $0.cropEndTime)
                }
            }
        ))
    }
    
    var body: some View {
        PerformanceMonitor.shared.recordViewUpdate("ContentView")
        
        return ZStack(alignment: .bottom) {
            TabView {
                DownloadsView(
                    downloadManager: downloadManager,
                    playlistManager: playlistManager,
                    audioPlayer: audioPlayer,
                    syncManager: syncManager,
                    showFolderPicker: $showFolderPicker,
                    showYouTubeDownload: $showYouTubeDownload
                )
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

                PlaylistsView(
                    playlistManager: playlistManager,
                    downloadManager: downloadManager,
                    audioPlayer: audioPlayer
                )
                .tabItem {
                    Label("Playlists", systemImage: "music.note.list")
                }

                QueueView(
                    audioPlayer: audioPlayer,
                    downloadManager: downloadManager
                )
                .tabItem {
                    Label("Queue", systemImage: "list.number")
                }
            }
            .onAppear {
                #if DEBUG
                startFPSTracking()
                MainThreadWatchdog.shared.start()
                #endif
                // Cloud replication + strongest cross-device track key. Done here
                // (not init) so the publishers observe fully-constructed objects.
                syncManager.attachReplication(
                    downloads: downloadManager.$downloads.eraseToAnyPublisher(),
                    failedDownloads: downloadManager.$failedDownloads.eraseToAnyPublisher(),
                    findDuplicate: { [weak downloadManager] yt in
                        downloadManager?.findDuplicateByVideoID(videoID: yt, source: .youtube)
                    },
                    startDownload: { [weak downloadManager] url, yt, source, title in
                        downloadManager?.startBackgroundDownload(url: url, videoID: yt, source: source, title: title)
                    })
                syncManager.attachPlaylists(manager: playlistManager) { [weak downloadManager] id in
                    downloadManager?.getDownload(byID: id)
                }
                syncManager.attachSettings(player: audioPlayer)
                TrackRef.ytIDProvider = { [weak downloadManager] track in
                    downloadManager?.getDownload(byID: track.id)?.videoID
                }
            }
            .task {
                // Silent reconnect with the saved home secret — the desktop app
                // does the same on boot, so devices find each other without UI.
                await syncManager.connectIfConfigured()
            }

            VStack(spacing: 0) {
                Spacer()
                
                if !downloadManager.failedDownloads.isEmpty {
                    FailedDownloadsBanner(downloadManager: downloadManager)
                        .padding(.bottom, 8)
                }
                
                if !downloadManager.activeDownloads.isEmpty {
                    DownloadBanner(downloadManager: downloadManager)
                        .padding(.bottom, 8)
                }
                
                if audioPlayer.currentTrack != nil || syncManager.engine.isRemoteControlled {
                    // Slim "next song" bar nested above the mini player. Renders
                    // nothing when there's no next track, so the mini bar sits
                    // alone in that case.
                    UpNextMiniBar(audioPlayer: audioPlayer, downloadManager: downloadManager)
                    MiniPlayerBar(audioPlayer: audioPlayer, downloadManager: downloadManager,
                                  syncManager: syncManager, showNowPlaying: $showNowPlaying)
                }
            }
            .padding(.bottom, 49)
        }
        // Now Playing lives in an .overlay, NOT as a ZStack(alignment: .bottom)
        // child. As a child, its .ignoresSafeArea() stretched the ZStack to the
        // full screen, dragging the .bottom anchor down — so the tab bar + mini
        // bar sat lower while it was up and JOLTED up the instant it unmounted.
        // An overlay never affects the host's layout, so they hold their place.
        .overlay {
            if showNowPlaying {
                NowPlayingView(
                    audioPlayer: audioPlayer,
                    downloadManager: downloadManager,
                    playlistManager: playlistManager,
                    syncManager: syncManager,
                    isPresented: $showNowPlaying,
                    panelOffset: $nowPlayingOffset
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
        // Auto-prompt to add completed download to playlist
        .sheet(item: $playlistPromptDownload) { download in
            AddToPlaylistSheet(
                download: download,
                playlistManager: playlistManager,
                onDismiss: {
                    playlistPromptDownload = nil
                }
            )
        }
        .onAppear {
            downloadManager.audioPlayer = audioPlayer
            
            // Give Siri / App Intents a live handle to playback so
            // "Hey Siri, play <song> in <app>" can reach the player. Any
            // request that arrived during a cold launch is fulfilled here.
            SiriPlaybackBridge.shared.attach(audioPlayer: audioPlayer, downloadManager: downloadManager)

            // Register/refresh the App Shortcut phrases AND the song-name
            // vocabulary. Without this, the shortcut grammar can stay empty and
            // Siri answers "hasn't added support for that" even though the
            // intent exists. Safe to call every launch.
            if #available(iOS 16.0, *) {
                MusicAppShortcuts.updateAppShortcutParameters()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !handlingDeepLink {
                    processIncomingShares()
                }
            }
            
            audioPlayer.onPlaybackEnded = {
                showNowPlaying = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !handlingDeepLink {
                    processIncomingShares()
                }
            }
        }
        // Library changed (download finished, rename, delete) → refresh Siri's
        // song vocabulary. Launch-only registration meant a song downloaded
        // mid-session wasn't recognized until the next app launch. Debounced:
        // batch playlist imports shouldn't hammer the system re-registration.
        .onReceive(
            downloadManager.$downloads
                .map { $0.filter { !$0.pendingDeletion }.map(\.name) }
                .removeDuplicates()
                .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
        ) { _ in
            if #available(iOS 16.0, *) {
                MusicAppShortcuts.updateAppShortcutParameters()
            }
        }
        // Listen for completed downloads and show prompt
        .onChange(of: downloadManager.completedDownloadForPlaylistPrompt?.id) { newID in
            guard newID != nil,
                  let download = downloadManager.completedDownloadForPlaylistPrompt else { return }
            
            // Only show if no other sheet is currently presented
            if !showFolderPicker && !showYouTubeDownload && !showNowPlaying {
                playlistPromptDownload = download
            }
            
            // Clear the trigger so it can fire again for the next download
            downloadManager.completedDownloadForPlaylistPrompt = nil
        }
        .onOpenURL { url in
            handlingDeepLink = true
            print("📥 App opened with URL: \(url)")
            handleIncomingURL(url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                handlingDeepLink = false
            }
        }
        // Hide the home indicator app-wide so the bottom safe-area inset is
        // CONSTANT. Now Playing presenting/dismissing no longer changes it, so
        // the tab bar + mini bar never jolt — and it's hidden on Now Playing too.
        .persistentSystemOverlays(.hidden)
    }

    // FPS tracking with CADisplayLink
    private func startFPSTracking() {
        let displayLink = CADisplayLink(target: FPSTracker.shared, selector: #selector(FPSTracker.tick))
        displayLink.add(to: .main, forMode: .common)
    }

    class FPSTracker {
        static let shared = FPSTracker()
        private var lastTimestamp: CFTimeInterval = 0
        
        @objc func tick(displayLink: CADisplayLink) {
            if lastTimestamp > 0 {
                // Calculate and record frame (fps calculation happens inside PerformanceMonitor)
                PerformanceMonitor.shared.recordFrame()
            }
            lastTimestamp = displayLink.timestamp
        }
    }

    private func handleIncomingURL(_ url: URL) {
        print("📥 App opened with URL: \(url)")
        
        let urlString = url.absoluteString
        
        // Handle custom scheme (from Share Extension)
        // e.g. musicApp://import?url=https://www.youtube.com/watch?v=xxx
        if url.scheme == "musicApp" || url.scheme == "pulsor" {
            // Extract the actual YouTube/Spotify URL directly from the deep link query param
            // This works even when App Groups are broken (sideloaded builds)
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let shareURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
               !shareURL.isEmpty {
                print("📥 [Share] Extracted URL from deep link: \(shareURL)")
                startDownload(from: shareURL, source: shareURL.contains("spotify") ? .spotify : .youtube)
                // Deep link had the URL — drain the App Group queue WITHOUT downloading
                // (just discard so it doesn't trigger a second download later)
                _ = IncomingShareQueue.drain()
            } else {
                // Deep link didn't have the URL — fall back to App Group queue
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.processIncomingShares()
                }
            }
            return
        }
        
        // Handle direct YouTube/Spotify URLs (not from Share Extension)
        if urlString.contains("youtube.com") || urlString.contains("youtu.be") {
            startDownload(from: urlString, source: .youtube)
        } else if urlString.contains("spotify.com") || urlString.contains("open.spotify.com") {
            startDownload(from: urlString, source: .spotify)
        }
    }

    private func startDownload(from urlString: String, source: DownloadSource) {
        guard let (detectedSource, videoID) = Self.extractVideoID(from: urlString) else {
            print("⚠️ Invalid URL format: \(urlString)")
            return
        }
        
        // Check for duplicates
        if downloadManager.findDuplicateByVideoID(videoID: videoID, source: detectedSource) == nil {
            downloadManager.startBackgroundDownload(
                url: urlString,
                videoID: videoID,
                source: detectedSource,
                title: detectedSource == .spotify ? "Converting Spotify" : "Downloading"
            )
        } else {
            print("⚠️ Skipping duplicate: \(videoID)")
        }
    }
    
    private func processIncomingShares() {
        let urls = IncomingShareQueue.drain()
        
        guard !urls.isEmpty else { return }
        
        print("📥 Processing \(urls.count) shared URLs")
        
        for urlString in urls {
            guard let (source, videoID) = Self.extractVideoID(from: urlString) else {
                print("⚠️ Invalid URL format: \(urlString)")
                continue
            }
            
            // Check for duplicates
            if downloadManager.findDuplicateByVideoID(videoID: videoID, source: source) != nil {
                print("⚠️ Skipping duplicate: \(videoID)")
                continue
            }
            
            downloadManager.startBackgroundDownload(
                url: urlString,
                videoID: videoID,
                source: source,
                title: source == .spotify ? "Converting Spotify" : "Downloading"
            )
        }
    }

    private static func extractVideoID(from urlString: String) -> (source: DownloadSource, id: String)? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""
        
        // YouTube detection
        if host.contains("youtube.com") || host.contains("youtu.be") || host.contains("m.youtube.com") {
            if host.contains("youtu.be") {
                let pathComponents = url.pathComponents.filter { $0 != "/" }
                if let videoID = pathComponents.first {
                    return (.youtube, videoID)
                }
            } else if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                      let queryItems = components.queryItems,
                      let videoID = queryItems.first(where: { $0.name == "v" })?.value {
                return (.youtube, videoID)
            }
        }
        
        // Spotify detection
        if host.contains("spotify.com") || host.contains("open.spotify.com") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            if let trackIndex = pathComponents.firstIndex(of: "track"), 
               trackIndex + 1 < pathComponents.count {
                var trackID = pathComponents[trackIndex + 1]
                // Remove query parameters
                if let queryIndex = trackID.firstIndex(of: "?") {
                    trackID = String(trackID[..<queryIndex])
                }
                return (.spotify, trackID)
            }
        }
        
        return nil
    }
}

// MARK: - Mini Player Bar
// Floating card: blurred artwork behind a smoke scrim, hairline seam,
// and a live ember progress line along the bottom edge.
// MARK: - Up Next mini bar
//
// Slim bar that peeks the immediate next track, nested just above the mini
// player on the main screen. Narrower than the mini bar so it reads as
// "stacked behind/above" it. Tap = jump to that song.
struct UpNextMiniBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager

    private var nextTrack: Track? { audioPlayer.upNextTracks.first }

    var body: some View {
        if let next = nextTrack {
            Button {
                if audioPlayer.queue.contains(where: { $0.id == next.id }) {
                    audioPlayer.playFromQueue(next)
                } else {
                    audioPlayer.play(next)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.redLight.opacity(0.9))
                    Text("UP NEXT")
                        .font(Theme.eyebrowFont)
                        .tracking(1.3)
                        .foregroundColor(Theme.redLight.opacity(0.9))
                    Text(next.name)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundColor(Theme.bone)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    AsyncThumbnailView(
                        thumbnailPath: downloadManager.getDownload(byID: next.id)?.resolvedThumbnailPath,
                        size: 26,
                        cornerRadius: 6
                    )
                    // Fresh view identity per track — async image state can
                    // never linger and show the PREVIOUS song's art next to
                    // the new song's title.
                    .id(next.id)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.smoke.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Theme.seam, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            // Inset more than the mini bar (12) so it nests above it.
            .padding(.horizontal, 22)
            .padding(.bottom, 5)
        }
    }
}

struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var syncManager: SyncSessionManager
    @Binding var showNowPlaying: Bool
    @State private var backgroundImage: UIImage?
    // Resolved once per track change (see refreshThumbnailPath()) instead of
    // recomputed in `body` on every 0.5s playback tick — the lookup involves
    // an array scan plus a disk `stat`, and the result never changes for the
    // same track.
    @State private var cachedThumbnailPath: String?

    private var progress: CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return CGFloat(min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1))
    }

    private var isRemote: Bool { syncManager.engine.isRemoteControlled }
    private var remotePB: PlaybackState? { syncManager.engine.mirror }
    /// Local track when playing here; resolved remote track when following.
    private var activeTrack: Track? {
        isRemote ? syncManager.engine.mirrorTrack : audioPlayer.currentTrack
    }
    private var displayName: String {
        isRemote ? (remotePB?.track?.name ?? "Unknown")
                 : (audioPlayer.currentTrack?.name ?? "Unknown")
    }
    private var displayFolder: String {
        isRemote ? (remotePB?.track?.folder ?? "")
                 : (audioPlayer.currentTrack?.folderName ?? "")
    }
    private var displayIsPlaying: Bool {
        isRemote ? (remotePB?.isPlaying ?? false) : audioPlayer.isPlaying
    }
    private func remoteProgress(atMs now: Int) -> CGFloat {
        guard let pb = remotePB, pb.durationMs > 0 else { return 0 }
        let pos = Double(pb.positionMs(atServerMs: now))
        return CGFloat(min(max(pos / Double(pb.durationMs), 0), 1))
    }

    /// Resolve artwork the same way the lists do — through the Download
    /// record's stored thumbnail path — instead of guessing the filename
    /// from the audio URL. Falls back to the audio-derived path.
    private func refreshThumbnailPath() {
        guard let track = activeTrack else { cachedThumbnailPath = nil; return }
        if let stored = downloadManager.getDownload(byID: track.id)?.resolvedThumbnailPath,
           FileManager.default.fileExists(atPath: stored) {
            cachedThumbnailPath = stored
            return
        }
        let derived = Artwork.thumbnailURL(forAudioFileURL: track.url).path
        cachedThumbnailPath = FileManager.default.fileExists(atPath: derived) ? derived : nil
    }
    
    var body: some View {
        ZStack {
            // Blurred artwork backdrop
            if let bgImage = backgroundImage {
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 58)
                    .blur(radius: 30)
                    .clipped()
            } else {
                Theme.smoke
                    .frame(height: 58)
            }
            
            // Scrim for readability
            Theme.ink.opacity(0.45)
                .frame(height: 58)
            
            HStack(spacing: 12) {
                // Left side - thumbnail and text (fully tappable)
                HStack(spacing: 12) {
                    AsyncThumbnailView(
                        thumbnailPath: cachedThumbnailPath,
                        size: 42,
                        cornerRadius: 10
                    )
                    // The mini-player is a single persistent view, so its
                    // thumbnail keeps the same SwiftUI identity across songs and
                    // the previous track's async-loaded image lingers one song
                    // behind. Re-key on the track id to force a fresh load.
                    .id(activeTrack?.id ?? remotePB?.track?.id)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(Theme.body(15, weight: .semibold))
                            .lineLimit(1)
                            .foregroundColor(Theme.bone)
                            .shadow(color: .black.opacity(0.3), radius: 2)

                        HStack(spacing: 5) {
                            if isRemote {
                                Image(systemName: "laptopcomputer.and.iphone")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Theme.redLight.opacity(0.9))
                            }
                            Text(displayFolder.uppercased())
                                .font(Theme.eyebrowFont)
                                .tracking(1.2)
                                .foregroundColor(Theme.bone.opacity(0.7))
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.3), radius: 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    // NowPlayingView animates its own slide-up on appear.
                    showNowPlaying = true
                }

                Spacer()
                
                Button {
                    if isRemote {
                        if displayIsPlaying { syncManager.engine.requestPause() }
                        else { syncManager.engine.requestPlay() }
                    } else if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    Image(systemName: displayIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Theme.bone)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .buttonStyle(.plain)

                Button {
                    if isRemote { syncManager.engine.requestNext() }
                    else { audioPlayer.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(Theme.bone)
                        .frame(width: 32, height: 36)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 58)
        // Live progress hairline along the bottom edge
        .overlay(alignment: .bottomLeading) {
            if isRemote {
                // No local player ticks while following — extrapolate from the
                // mirror on a visible-only 0.5 s timeline.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    progressHairline(remoteProgress(atMs: ServerClock.shared.nowMs))
                }
            } else {
                progressHairline(progress)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.seam, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
        .onChange(of: activeTrack?.id) { _ in
            refreshThumbnailPath()
            updateBackgroundImage()
        }
        .onAppear {
            refreshThumbnailPath()
            updateBackgroundImage()
        }
    }

    private func progressHairline(_ p: CGFloat) -> some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.emberGradient)
                .frame(width: max(geo.size.width * p, 0), height: 2.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    private func updateBackgroundImage() {
        guard let track = activeTrack else {
            backgroundImage = nil
            return
        }

        let audioURL = track.url
        let path = cachedThumbnailPath
        // Disk read + crop off the main thread so swapping tracks never
        // hitches the UI (the foreground artwork is handled by AsyncThumbnailView).
        DispatchQueue.global(qos: .userInitiated).async {
            PerformanceMonitor.shared.start("NowPlayingView_UpdateBackground")
            // Wide aspect crop for the mini player
            let cropped: UIImage?
            if let path = path {
                cropped = Artwork.croppedBackground(atPath: path, aspect: 4.0)
            } else {
                cropped = Artwork.croppedBackground(forAudioFileURL: audioURL, aspect: 4.0)
            }
            PerformanceMonitor.shared.end("NowPlayingView_UpdateBackground")
            DispatchQueue.main.async {
                // Only apply if we're still on the same track
                if self.activeTrack?.url == audioURL {
                    self.backgroundImage = cropped
                }
            }
        }
    }
}

// MARK: - Full Now Playing View
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    @ObservedObject var syncManager: SyncSessionManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var switchingHere = false
    @State private var localSeekPosition: Double = 0
    @State private var showPlaylistPicker = false
    @State private var backgroundImage: UIImage?
    @State private var showRenameAlert = false
    @State private var newTrackName: String = ""
    @State private var showAudioSettings = false
    @State private var showCropSheet = false
    @State private var showUpNext = false
    @State private var showLyrics = false
    @StateObject private var lyrics = LyricsService()
    // Resolved once per track change (see refreshThumbnailImage()) instead of
    // recomputed in `body` on every 0.5s playback tick.
    @State private var cachedNowPlayingThumbnail: UIImage?
    // Title text-width measurement (Core Text) only changes with the track,
    // not with the 0.5s playback tick — cache it instead of remeasuring every
    // time titleView's body re-evaluates.
    @State private var cachedTitleText: String = "Unknown"
    @State private var cachedTitleWidth: CGFloat = 0
    // Panel position, owned by ContentView so the mini player can crossfade with
    // the slide. A full screen below = off-screen (onAppear animates it up);
    // dismiss animates it back down. Offset-only (no SwiftUI .transition).
    @Binding var panelOffset: CGFloat
    
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isSeeking ? localSeekPosition : audioPlayer.currentTime },
            set: { newValue in
                localSeekPosition = newValue
                if !isSeeking {
                    audioPlayer.seek(to: newValue)
                }
            }
        )
    }

    /// Another device currently owns the shared session — this screen shows
    /// what's playing there but can't control it until you take over.
    private var isRemoteControlled: Bool {
        syncManager.coordinator.role == .follower &&
        !(syncManager.coordinator.remote?.ownerDeviceID.isEmpty ?? true)
    }

    var body: some View {
        PerformanceMonitor.shared.recordViewUpdate("NowPlayingView")
        
        return ZStack {
            // Backdrop that dims the list behind as the panel rises (and clears
            // as it falls). Tied to slide progress, so the card blends over a
            // darkening list instead of cutting a hard bright/dark seam — a
            // smooth, intentional sheet feel. This layer does NOT slide.
            Color.black
                .opacity(0.55 * (1.0 - Double(min(max(panelOffset / UIScreen.main.bounds.height, 0), 1))))
                .ignoresSafeArea()

            // The Now Playing panel — this is the part that slides.
            ZStack {
                // Opaque floor so the list never shows through the blurred art.
                Color.black
                    .ignoresSafeArea()

                backgroundLayer

                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                // Foreground content. Deliberately does NOT ignoreSafeArea, so
                // SwiftUI insets it: top bar clears the notch, volume bar clears
                // the home indicator.
                VStack(spacing: 0) {
                    topBar

                    Spacer(minLength: 4)

                    thumbnailView

                    Spacer(minLength: 8)

                    controlsSection
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // More top → top buttons sit lower, clear of the notch.
                // More bottom → volume bar rises out of the bottom edge-swipe zone.
                .padding(.top, 50)
                .padding(.bottom, 30)
                .blur(radius: isRemoteControlled ? 18 : 0)
                .allowsHitTesting(!isRemoteControlled)

                if isRemoteControlled {
                    remoteLockOverlay
                }
            }
            // Single source of truth for present, drag, and dismiss motion.
            .offset(y: panelOffset)
            // Fade once it slides past 60% of the screen, fully gone by the
            // bottom (+30px). Position-based, so the present fades it back in as
            // it rises above that threshold.
            .opacity(1.0 - Double(min(max((panelOffset - 0.6 * UIScreen.main.bounds.height) / (0.4 * UIScreen.main.bounds.height + 30), 0), 1)))
        }
        .onAppear {
            updateBackgroundImage()
            refreshThumbnailImage()
            refreshTitleMetrics()
            lockOrientation(.portrait)
            audioPlayer.startVisualization()
            // Slide up into place (panel starts off-screen below).
            withAnimation(.easeInOut(duration: 0.3)) { panelOffset = 0 }
        }
        .onDisappear {
            unlockOrientation()
            audioPlayer.stopVisualization()
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            updateBackgroundImage()
            refreshThumbnailImage()
            refreshTitleMetrics()
        }
        // Plain .gesture (NOT highPriority) so child controls — the volume bar
        // and progress slider — still receive their own drags. The dismiss drag
        // only takes over in the empty areas (background, thumbnail).
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    let dy = value.translation.height
                    if dy > 0 {
                        // On the first downward move, freeze the visualizer (a live
                        // 60fps Canvas translated every frame stutters) and lock its
                        // center (else it slides at double speed).
                        // Freeze the FFT on the first downward move so the bars
                        // hold their shape and slide with the artwork (cheaper
                        // than redrawing a live Canvas every frame mid-drag).
                        if panelOffset == 0 { audioPlayer.isVisualizerVisible = false }
                        panelOffset = dy                // 1:1 with the finger
                    } else {
                        panelOffset = 0                 // ignore upward travel here
                    }
                }
                .onEnded { value in
                    let dy = value.translation.height
                    let vy = value.predictedEndTranslation.height
                    if dy > 120 || vy > 600 {
                        animatedDismiss()
                    } else if dy < -90 || vy < -300 {
                        // Swipe up → audio settings; unfreeze and settle back.
                        audioPlayer.isVisualizerVisible = true
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { panelOffset = 0 }
                        showAudioSettings = true
                    } else {
                        // Not far enough → spring back and resume the visualizer.
                        audioPlayer.isVisualizerVisible = true
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            panelOffset = 0
                        }
                    }
                }
        )
        .sheet(isPresented: $showPlaylistPicker) {
            if let track = audioPlayer.currentTrack,
            let download = downloadManager.getDownload(byID: track.id) {
                AddToPlaylistSheet(
                    download: download,
                    playlistManager: playlistManager,
                    onDismiss: { showPlaylistPicker = false }
                )
            }
        }
        .sheet(isPresented: $showAudioSettings) {
            AudioSettingsSheet(audioPlayer: audioPlayer)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCropSheet) {
            if let track = audioPlayer.currentTrack {
                CropSongSheet(
                    track: track,
                    downloadManager: downloadManager,
                    audioPlayer: audioPlayer
                )
            }
        }
        .sheet(isPresented: $showUpNext) {
            UpNextSheet(
                audioPlayer: audioPlayer,
                downloadManager: downloadManager,
                isPresented: $showUpNext
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLyrics) {
            LyricsView(
                audioPlayer: audioPlayer,
                downloadManager: downloadManager,
                lyrics: lyrics
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .themedTextPrompt(
            "Rename Song",
            placeholder: "Song name",
            text: $newTrackName,
            isPresented: $showRenameAlert,
            confirmLabel: "Rename"
        ) {
            if let track = audioPlayer.currentTrack,
            let download = downloadManager.downloads.first(where: { $0.url == track.url }) {
                downloadManager.renameDownload(download, newName: newTrackName)
            }
        }
    }
    
    // MARK: - Extracted Subviews
    
    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            if let bgImage = backgroundImage {
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    .blur(radius: 55)
                    .scaleEffect(1.3)
                    // Desaturate toward the red/black identity so wildly
                    // colored artwork doesn't fight the theme.
                    .saturation(0.65)
                    .overlay(Theme.ink.opacity(0.35))
            } else {
                Theme.ink
            }
            
            // Red glow rising from the bottom — the signature of the
            // red/black Now Playing screen.
            RadialGradient(
                colors: [Theme.red.opacity(0.28), .clear],
                center: .bottom,
                startRadius: 10,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var remoteLockOverlay: some View {
        VStack(spacing: 16) {
            Text("Playing on your other device")
                .font(Theme.body(15, weight: .semibold))
                .foregroundColor(Theme.bone)
            if let name = syncManager.coordinator.remote?.playback.track?.name {
                Text(name)
                    .font(Theme.caption(13))
                    .foregroundColor(Theme.boneDim)
                    .lineLimit(1)
            }
            Button(switchingHere ? "Switching…" : "Play Here") {
                switchingHere = true
                Task {
                    defer { switchingHere = false }
                    try? await syncManager.playHere()
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(switchingHere)
            .frame(maxWidth: 220)
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.smokeRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Theme.seam, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 20)
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                animatedDismiss()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))

            Spacer()

            // Up Next — opens the queue as a half-sheet (separate layer, so it
            // can't push any of these controls off-screen).
            Button {
                showUpNext = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    audioPlayer.isLoopEnabled.toggle()
                }
            } label: {
                Image(systemName: "repeat")
                    .rotationEffect(.degrees(audioPlayer.isLoopEnabled ? 360 : 0))
            }
            .buttonStyle(CircleControlButtonStyle(
                diameter: 40,
                tint: audioPlayer.isLoopEnabled ? Theme.ink : Theme.bone,
                filled: audioPlayer.isLoopEnabled
            ))
            
            Button {
                audioPlayer.effectsBypass.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
            }
            .buttonStyle(CircleControlButtonStyle(
                diameter: 40,
                tint: audioPlayer.effectsBypass ? Theme.bone : Theme.ink,
                filled: !audioPlayer.effectsBypass
            ))
            
            // Every option is a first-class button — no ⋯ menu. Six options
            // after the dismiss chevron: up next, loop, effects, lyrics,
            // add-to-playlist, crop.
            Button {
                showLyrics = true
            } label: {
                Image(systemName: "quote.bubble")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))

            Button {
                showPlaylistPicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))

            Button {
                showCropSheet = true
            } label: {
                Image(systemName: "scissors")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        PulsingThumbnailView(
            visualizerState: audioPlayer.visualizerState,
            thumbnailImage: cachedNowPlayingThumbnail,
            onTap: {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            }
        )
        .overlay(
            // Visualizer glued onto the artwork as an overlay — same layout unit,
            // so it slides and pulses WITH the thumbnail. No global-center
            // tracking, no double translation, no detaching during the slide.
            EdgeVisualizerView(
                audioPlayer: audioPlayer,
                visualizerState: audioPlayer.visualizerState
            )
            .frame(width: 440, height: 440)
            .allowsHitTesting(false)
        )
    }
    
    @ViewBuilder
    private var controlsSection: some View {
        VStack(spacing: 0) {
            titleView
            progressBar
            playbackControls
            volumeBar
            upNextStrip
        }
        .padding(.bottom, 12)
    }

    // Persistent "next song" strip — shows ONLY the immediate next track
    // (queued song first, else next playlist track).
    //
    // UNCONDITIONAL on purpose. A `if let next { … }` here gives the strip its
    // own view identity, so on the panel's animated mount SwiftUI INSERTS it
    // (default .opacity transition) instead of letting it ride the panel offset
    // like the unconditional siblings (title/controls/volume) — that's the
    // fade. Keeping the Button always in the tree and collapsing it to zero
    // height/opacity when there's no next track makes it structurally identical
    // to its siblings: it slides up/down with the panel, never fades on its own.
    @ViewBuilder
    private var upNextStrip: some View {
        let next = audioPlayer.upNextTracks.first
        Button {
            if let next { skipToNext(next) }
        } label: {
            HStack(spacing: 10) {
                AsyncThumbnailView(
                    thumbnailPath: next.flatMap { downloadManager.getDownload(byID: $0.id)?.resolvedThumbnailPath },
                    size: 34,
                    cornerRadius: 7
                )
                // Same fix as UpNextMiniBar: identity keyed to the track so
                // image and title can never belong to different songs.
                .id(next?.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text("UP NEXT")
                        .font(Theme.eyebrowFont)
                        .tracking(1.4)
                        .foregroundColor(Theme.redLight.opacity(0.9))
                    Text(next?.name ?? "")
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundColor(Theme.bone)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.boneFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.smokeRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.seam, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(next == nil)
        .allowsHitTesting(next != nil)
        // Collapse to nothing when there's no next track — same footprint as the
        // old conditional, no overflow, but the view identity stays stable.
        .frame(height: next == nil ? 0 : nil)
        .opacity(next == nil ? 0 : 1)
        .clipped()
        .padding(.top, next == nil ? 0 : 14)
        .padding(.horizontal, 24)
    }

    /// Jump straight to the upcoming track. A queued song is pulled from the
    /// queue and played; a playlist track just plays.
    private func skipToNext(_ track: Track) {
        if audioPlayer.queue.contains(where: { $0.id == track.id }) {
            audioPlayer.playFromQueue(track)
        } else {
            audioPlayer.play(track)
        }
    }
    
    @ViewBuilder
    private var titleView: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let needsScroll = cachedTitleWidth > geometry.size.width

                ZStack {
                    if needsScroll {
                        ScrollingTextView(
                            text: cachedTitleText,
                            font: Theme.display(28),
                            width: geometry.size.width
                        )
                    } else {
                        Text(cachedTitleText)
                            .font(Theme.display(28))
                            .foregroundColor(Theme.bone)
                            .frame(width: geometry.size.width, alignment: .center)
                    }
                }
                .onTapGesture {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                }
                .onLongPressGesture {
                    if let track = audioPlayer.currentTrack {
                        newTrackName = track.name
                        showRenameAlert = true
                    }
                }
            }
            .frame(height: 40)
            
            // Crop indicator badge
            if let track = audioPlayer.currentTrack,
               track.cropStartTime != nil || track.cropEndTime != nil {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.system(size: 10, weight: .semibold))
                    Text("CROPPED")
                        .font(Theme.eyebrowFont)
                        .tracking(1.2)
                }
                .foregroundColor(Theme.redLight)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.redDeep.opacity(0.22)))
                .overlay(Capsule().strokeBorder(Theme.redLight.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(.horizontal, 28)
    }
    
    @ViewBuilder
    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                
                Text("-" + formatTime((audioPlayer.duration - (isSeeking ? localSeekPosition : audioPlayer.currentTime)) / audioPlayer.effectivePlaybackSpeed))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
            }
            
            ThemedSlider(
                value: sliderBinding,
                range: 0...max(audioPlayer.duration, 1),
                tint: Theme.redLight
            ) { editing in
                isSeeking = editing
                if editing {
                    localSeekPosition = audioPlayer.currentTime
                } else {
                    audioPlayer.seek(to: localSeekPosition)
                }
            }
            .disabled(audioPlayer.duration == 0)
            
            HStack {
                Text(formatTime(isSeeking ? localSeekPosition : audioPlayer.currentTime))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
                
                Spacer()
                
                Text(formatTime(audioPlayer.duration))
                    .font(Theme.caption(12).monospacedDigit())
                    .foregroundColor(Theme.bone.opacity(0.7))
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
    }
    
    @ViewBuilder
    private var playbackControls: some View {
        HStack(spacing: 14) {
            Button { audioPlayer.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 46, tint: Theme.bone))
            
            RewindButton(audioPlayer: audioPlayer)
            
            // Primary play/pause — red gradient, glow, press-spring.
            Button {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(PlayButtonStyle(diameter: 76))
            
            FastForwardButton(audioPlayer: audioPlayer)
            
            Button { audioPlayer.next() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 46, tint: Theme.bone))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }
    
    @ViewBuilder
    private var volumeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundColor(Theme.redLight.opacity(0.8))
                .font(.caption)
            VolumeSlider()
                .frame(height: 20)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(Theme.redLight.opacity(0.8))
                .font(.caption)
        }
        .padding(.horizontal, 36)
        .padding(.top, 16)
    }
    
    private func updateBackgroundImage() {
        guard let track = audioPlayer.currentTrack else {
            backgroundImage = nil
            return
        }

        let audioURL = track.url
        // Screen-aspect crop for the full-screen backdrop
        let screenAspect = UIScreen.main.bounds.width / UIScreen.main.bounds.height
        // Disk read + crop off the main thread so this doesn't compete with
        // the sheet's slide-up animation (matches MiniPlayerBar's version).
        DispatchQueue.global(qos: .userInitiated).async {
            let cropped = Artwork.croppedBackground(forAudioFileURL: audioURL, aspect: screenAspect)
            DispatchQueue.main.async {
                if self.audioPlayer.currentTrack?.url == audioURL {
                    self.backgroundImage = cropped
                }
            }
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Resolves and caches the Now Playing thumbnail for the current track.
    /// Called on track change (onAppear/onChange), not from `body` — the path
    /// resolution below never changes for the same track.
    private func refreshThumbnailImage() {
        cachedNowPlayingThumbnail = getThumbnailImage(for: audioPlayer.currentTrack)
    }

    /// Re-measures the title text width once per track change instead of on
    /// every playback tick — see cachedTitleText/cachedTitleWidth above.
    private func refreshTitleMetrics() {
        let text = audioPlayer.currentTrack?.name ?? "Unknown"
        cachedTitleText = text
        cachedTitleWidth = text.widthOfString(usingFont: Theme.roundedUIFont(size: 28, weight: .heavy))
    }

    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track else { return nil }

        // Prefer the Download record's stored thumbnail path (the same source
        // the lists use); fall back to the audio-derived path.
        let pathString: String
        if let stored = downloadManager.getDownload(byID: track.id)?.resolvedThumbnailPath,
           FileManager.default.fileExists(atPath: stored) {
            pathString = stored
        } else if let derived = EmbeddedPython.shared.getThumbnailPath(for: track.url) {
            pathString = derived.path
        } else {
            return nil
        }

        // ⚡ Use a size-specific cache key so list thumbnails (48px) don't conflict with NowPlaying (200px)
        let cacheKey = pathString + "_nowplaying"
        if let cached = ThumbnailCache.shared.get(cacheKey) {
            return cached
        }

        // Load full resolution for NowPlaying (200pt = 600px @3x retina)
        guard let image = UIImage(contentsOfFile: pathString) else { return nil }
        ThumbnailCache.shared.set(cacheKey, image: image)
        return image
    }
    
    /// Slide the panel down off-screen, then unmount once it's fully gone.
    /// Offset-only (no SwiftUI .transition) so nothing is left rendering behind.
    private func animatedDismiss() {
        audioPlayer.isVisualizerVisible = false   // freeze bars; they slide out with the panel
        withAnimation(.easeInOut(duration: 0.3)) {
            panelOffset = UIScreen.main.bounds.height + 30   // +30 so it fully clears the bottom
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isPresented = false
        }
    }

    private func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
        AppDelegate.orientationLock = orientation
    }
    
    private func unlockOrientation() {
        AppDelegate.orientationLock = .all
    }
}


// MARK: - Up Next sheet
//
// Presented from Now Playing as a half-sheet. It's a separate presentation
// layer, so it never affects the Now Playing layout — nothing can be pushed
// off-screen — and it floats above everything, including the mini player.
struct UpNextSheet: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            ZStack {
                Theme.ink.ignoresSafeArea()

                let upNext = audioPlayer.upNextTracks
                if upNext.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.boneFaint)
                        Text("Nothing up next")
                            .font(Theme.body(15, weight: .semibold))
                            .foregroundColor(Theme.boneDim)
                        Text("Swipe right on songs to queue them")
                            .font(Theme.caption(12))
                            .foregroundColor(Theme.boneFaint)
                    }
                    .padding()
                } else {
                    List {
                        // Index-keyed so a song queued twice can't collide ids.
                        ForEach(Array(upNext.enumerated()), id: \.offset) { _, track in
                            UpNextRow(track: track, downloadManager: downloadManager)
                                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .contentShape(Rectangle())
                                .onTapGesture { skipTo(track) }
                        }
                        .onDelete(perform: deleteRows)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { isPresented = false }
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
    }

    private func skipTo(_ track: Track) {
        // A user-queued track is removed from the queue and played; a playlist
        // up-next track just plays.
        if audioPlayer.queue.contains(where: { $0.id == track.id }) {
            audioPlayer.playFromQueue(track)
        } else {
            audioPlayer.play(track)
        }
        isPresented = false
    }

    private func deleteRows(at offsets: IndexSet) {
        // upNextTracks = queue (first) + playlist upcoming. Only the queue block
        // is removable via removeFromQueue.
        let queueCount = audioPlayer.queue.count
        let queueOffsets = IndexSet(offsets.filter { $0 < queueCount })
        guard !queueOffsets.isEmpty else { return }
        audioPlayer.removeFromQueue(at: queueOffsets)
    }
}

struct UpNextRow: View {
    let track: Track
    @ObservedObject var downloadManager: DownloadManager

    private var download: Download? {
        downloadManager.getDownload(byID: track.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncThumbnailView(
                thumbnailPath: download?.resolvedThumbnailPath,
                size: 44,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(Theme.body(15, weight: .medium))
                    .foregroundColor(Theme.bone)
                    .lineLimit(1)
                Text(track.folderName)
                    .font(Theme.caption(11))
                    .foregroundColor(Theme.boneFaint)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .surfaceCard()
    }
}

// MARK: - Rewind/Forward Buttons
struct RewindButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var isLongPressing = false
    @State private var pressTimer: Timer?
    @State private var rewindTimer: Timer?
    
    var body: some View {
        Image("rewind")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
            .foregroundColor(Theme.bone)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Theme.smokeRaised))
            .overlay(Circle().strokeBorder(Theme.seam, lineWidth: 1))
            .scaleEffect(isLongPressing ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isLongPressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressTimer == nil {
                            pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                isLongPressing = true
                                
                                rewindTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                                    audioPlayer.skip(seconds: -0.5)
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        pressTimer?.invalidate()
                        pressTimer = nil
                        
                        rewindTimer?.invalidate()
                        rewindTimer = nil
                        
                        if isLongPressing {
                            isLongPressing = false
                        } else {
                            audioPlayer.skip(seconds: -10)
                        }
                    }
            )
    }
}

struct FastForwardButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var isLongPressing = false
    @State private var pressTimer: Timer?
    
    var body: some View {
        Image("forward")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: 22, height: 22)
            .foregroundColor(Theme.bone)
            .frame(width: 46, height: 46)
            .background(Circle().fill(Theme.smokeRaised))
            .overlay(Circle().strokeBorder(Theme.seam, lineWidth: 1))
            .scaleEffect(isLongPressing ? 0.9 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isLongPressing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressTimer == nil {
                            pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                isLongPressing = true
                                audioPlayer.setTemporarySpeed(2.0)
                            }
                        }
                    }
                    .onEnded { _ in
                        pressTimer?.invalidate()
                        pressTimer = nil
                        
                        if isLongPressing {
                            audioPlayer.setTemporarySpeed(nil)
                            isLongPressing = false
                        } else {
                            audioPlayer.skip(seconds: 10)
                        }
                    }
            )
    }
}

struct VolumeSlider: UIViewRepresentable {

    func makeUIView(context: Context) -> VolumeContainerView {
        VolumeContainerView()
    }
    
    func updateUIView(_ uiView: VolumeContainerView, context: Context) {
        uiView.applyStyle()
    }
}

class VolumeContainerView: UIView {
    private let volumeView = MPVolumeView()
    private var observer: NSKeyValueObservation?
    private var isApplying = false

    // Generate the custom artwork ONCE and reuse it. Re-applying is then cheap
    // enough to do synchronously on every layout pass — which is what stops the
    // stock slider from flashing through during gestures/scrolls.
    private lazy var trackFill: UIImage = makeTrackImage(
        colors: [UIColor(Theme.redLight), UIColor(Theme.redDeep)], height: 6)
    private lazy var trackEmpty: UIImage = makeTrackImage(
        colors: [UIColor(Theme.smokeRaised), UIColor(Theme.smokeRaised)], height: 6)
    private lazy var thumb: UIImage = makeThumb(size: 16)

    deinit {
        observer?.invalidate()
        observer = nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        volumeView.showsVolumeSlider = true
        // showsRouteButton was deprecated in iOS 13; use AVRoutePickerView if
        // AirPlay UI is ever needed.
        volumeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(volumeView)
        NSLayoutConstraint.activate([
            volumeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumeView.topAnchor.constraint(equalTo: topAnchor),
            volumeView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // MPVolumeView recreates its slider subview on route/layout changes.
        // Re-style synchronously the instant that happens — no async gap.
        observer = volumeView.observe(\.subviews, options: [.new]) { [weak self] _, _ in
            self?.applyStyle()
        }

        applyStyle()
    }

    /// Re-apply the custom look. Synchronous and idempotent: it only writes the
    /// images when the slider is missing them (e.g. after MPVolumeView reset
    /// them), so calling it every layout pass can't loop.
    func applyStyle() {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        for case let button as UIButton in volumeView.subviews {
            button.isHidden = true
            button.alpha = 0
        }

        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
            return
        }

        // Already wearing our artwork → nothing to do (prevents relayout loops).
        guard slider.thumbImage(for: .normal) !== thumb else { return }

        slider.minimumTrackTintColor = nil
        slider.maximumTrackTintColor = nil
        slider.thumbTintColor = nil

        UIView.performWithoutAnimation {
            slider.setMinimumTrackImage(trackFill, for: .normal)
            slider.setMaximumTrackImage(trackEmpty, for: .normal)
            slider.setThumbImage(thumb, for: .normal)
            slider.setThumbImage(thumb, for: .highlighted)
        }
    }
    
    /// A horizontal rounded-capsule track image (resizable) drawn with a
    /// left-to-right gradient.
    private func makeTrackImage(colors: [UIColor], height: CGFloat) -> UIImage {
        // Width just needs to exceed the corner radius on both ends; the
        // image is stretched via cap insets.
        let width = height * 3
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: height / 2)
            path.addClip()
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let cgColors = colors.map { $0.cgColor } as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: [0, 1]) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: width, y: 0),
                    options: []
                )
            }
        }
        // Cap insets so the rounded ends stay crisp when stretched.
        let cap = height / 2
        return image
            .resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: cap, bottom: 0, right: cap),
                            resizingMode: .stretch)
            .withRenderingMode(.alwaysOriginal)
    }
    
    private func makeThumb(size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            // Soft shadow so the thumb reads on dark backgrounds.
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1),
                                    blur: 3,
                                    color: UIColor.black.withAlphaComponent(0.5).cgColor)
            UIColor(Theme.bone).setFill()
            ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
            // Thin red ring.
            ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(Theme.red).setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Force MPVolumeView to finish its own layout (the step that resets the
        // slider to the stock look) FIRST, then paint our images over it in the
        // same pass so the default never reaches the screen.
        volumeView.layoutIfNeeded()
        applyStyle()
    }
}

// MARK: - Audio Settings Sheet
struct AudioSettingsSheet: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    // Per-control accents — red family, varied by intensity so each
    // control still reads as distinct.
    private let speedColor = Theme.redLight
    private let pitchColor = Theme.rose
    private let reverbColor = Color(red: 1.0, green: 0.45, blue: 0.38) // warm coral
    private let bassColor = Theme.redDeep
    
    private var speedBinding: Binding<Double> {
        Binding(
            get: { audioPlayer.playbackSpeed },
            set: { newValue in
                let rounded = (newValue * 10).rounded() / 10
                audioPlayer.playbackSpeed = rounded
            }
        )
    }
    
    private var pitchBinding: Binding<Double> {
        Binding(
            get: { audioPlayer.pitchShift },
            set: { newValue in
                let rounded = (newValue * 2).rounded() / 2
                audioPlayer.pitchShift = rounded
            }
        )
    }
    
    private var hasAnyChanges: Bool {
        audioPlayer.playbackSpeed != 1.0 ||
        audioPlayer.pitchShift != 0 ||
        audioPlayer.reverbAmount != 0 ||
        audioPlayer.bassBoost != 0
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                AppBackground()
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Speed
                        settingCard(
                            icon: "gauge.with.needle",
                            title: "Speed",
                            valueText: String(format: "%.1fx", audioPlayer.playbackSpeed),
                            unit: nil,
                            color: speedColor,
                            minLabel: "0.5x",
                            maxLabel: "2.0x",
                            slider: AnyView(
                                ThemedSlider(value: speedBinding, range: 0.5...2.0, tint: speedColor)
                            ),
                            onReset: { audioPlayer.playbackSpeed = 1.0 }
                        )
                        
                        // Pitch
                        settingCard(
                            icon: "music.note",
                            title: "Pitch",
                            valueText: audioPlayer.pitchShift == 0 ? "0" : String(format: "%+.1f", audioPlayer.pitchShift),
                            unit: "st",
                            color: pitchColor,
                            minLabel: "-12",
                            maxLabel: "+12",
                            slider: AnyView(
                                ThemedSlider(value: pitchBinding, range: -12...12, tint: pitchColor)
                            ),
                            onReset: { audioPlayer.pitchShift = 0 }
                        )
                        
                        // Reverb
                        settingCard(
                            icon: "waveform.path",
                            title: "Reverb",
                            valueText: "\(Int(audioPlayer.reverbAmount))%",
                            unit: nil,
                            color: reverbColor,
                            minLabel: "0%",
                            maxLabel: "100%",
                            slider: AnyView(
                                ThemedSlider(value: $audioPlayer.reverbAmount, range: 0...100, tint: reverbColor)
                            ),
                            onReset: { audioPlayer.reverbAmount = 0 }
                        )
                        
                        // Bass Boost
                        settingCard(
                            icon: "speaker.wave.3.fill",
                            title: "Bass Boost",
                            valueText: audioPlayer.bassBoost == 0 ? "0" : String(format: "%+.0f", audioPlayer.bassBoost),
                            unit: "dB",
                            color: bassColor,
                            minLabel: "-10",
                            maxLabel: "+20",
                            slider: AnyView(
                                ThemedSlider(value: $audioPlayer.bassBoost, range: -10...20, tint: bassColor)
                            ),
                            onReset: { audioPlayer.bassBoost = 0 }
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("DJ Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if hasAnyChanges {
                        Button("Reset All") {
                            audioPlayer.playbackSpeed = 1.0
                            audioPlayer.pitchShift = 0
                            audioPlayer.reverbAmount = 0
                            audioPlayer.bassBoost = 0
                        }
                        .buttonStyle(ChipButtonStyle(tint: Theme.emberLight))
                    }
                }
            }
        }
    }
    
    private func settingCard(
        icon: String,
        title: String,
        valueText: String,
        unit: String?,
        color: Color,
        minLabel: String,
        maxLabel: String,
        slider: AnyView,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 24)
                Text(title.uppercased())
                    .font(Theme.eyebrowFont)
                    .tracking(1.5)
                    .foregroundColor(Theme.boneDim)
                Spacer()
                Text(valueText)
                    .font(Theme.body(15, weight: .semibold).monospacedDigit())
                    .foregroundColor(Theme.bone)
                if let unit = unit {
                    Text(unit)
                        .font(Theme.caption(11))
                        .foregroundColor(Theme.boneDim)
                }
            }
            
            slider
            
            HStack {
                Text(minLabel)
                    .font(Theme.caption(11))
                    .foregroundColor(Theme.boneFaint)
                Spacer()
                Button("Reset", action: onReset)
                    .buttonStyle(ChipButtonStyle(tint: color))
                Spacer()
                Text(maxLabel)
                    .font(Theme.caption(11))
                    .foregroundColor(Theme.boneFaint)
            }
        }
        .padding(16)
        .surfaceCard()
    }
}

struct DownloadBanner: View {
    @ObservedObject var downloadManager: DownloadManager
    
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let dotCount = Int(timeline.date.timeIntervalSince1970 * 2) % 3 + 1
            
            VStack(spacing: 8) {
                ForEach(downloadManager.activeDownloads) { download in
                    HStack(spacing: 12) {
                        EQIndicator(color: Theme.emberLight, scale: 1.15)

                        Text("\(download.title)\(String(repeating: ".", count: dotCount))")
                            .font(Theme.body(14, weight: .medium))
                            .foregroundColor(Theme.bone)
                            .lineLimit(1)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .surfaceCard(corner: 14)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct FailedDownloadsBanner: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var expanded = false
    
    var body: some View {
        VStack(spacing: 6) {
            // Header — tap to expand/collapse
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Theme.emberLight)
                    .font(.system(size: 14, weight: .semibold))
                
                Text("\(downloadManager.failedDownloads.count) download\(downloadManager.failedDownloads.count == 1 ? "" : "s") failed")
                    .font(Theme.body(14, weight: .semibold))
                    .foregroundColor(Theme.bone)
                
                Spacer()
                
                // Expand / collapse chevron
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.boneDim)
                
                // Dismiss all
                Button {
                    withAnimation { downloadManager.failedDownloads.removeAll() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.boneDim)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { expanded.toggle() } }
            
            // Expanded detail list
            if expanded {
                VStack(spacing: 6) {
                    ForEach(downloadManager.failedDownloads) { failed in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failed.title)
                                .font(Theme.caption(12, weight: .semibold))
                                .foregroundColor(Theme.bone)
                                .lineLimit(1)
                            Text(failed.error)
                                .font(Theme.caption(11, weight: .regular))
                                .foregroundColor(Theme.danger.opacity(0.9))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .surfaceCard(corner: 14)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.horizontal, 16)
    }
}


// MARK: - Pulsing Thumbnail (directly observes VisualizerState for 60fps sync)
struct PulsingThumbnailView: View {
    @ObservedObject var visualizerState: VisualizerState
    let thumbnailImage: UIImage?
    var onTap: (() -> Void)? = nil
    
    var body: some View {
        PerformanceMonitor.shared.recordViewUpdate("PulsingThumbnailView")
        
        return Group {
            if let thumbnailImage = thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.8), radius: 25, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(
                        colors: [Theme.smokeRaised, Theme.smoke],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 200, height: 200)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundColor(Theme.bone.opacity(0.5))
                    )
                    .shadow(color: .black.opacity(0.8), radius: 25, y: 8)
            }
        }
        .scaleEffect(1.0 + CGFloat(visualizerState.bassLevel) * 0.20)
        .onTapGesture {
            onTap?()
        }
    }
}

// MARK: - Edge Visualizer (Beat-synced with dynamic range)
struct EdgeVisualizerView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var visualizerState: VisualizerState
    var thumbnailCenter: CGPoint? = nil  // If provided, draw around this point instead of view center
    
    // Geometry - matches thumbnail with subtle pulse
    private let baseBoxSize: CGFloat = 200
    private let cornerRadius: CGFloat = 16
    private let maxBarLength: CGFloat = 60
    private let minBarLength: CGFloat = 1
    private let barsPerSide = 25  // 100 total bars = matches FFT bins
    
    // ⚡ Pre-computed HSB values per bar index (updated only on track change)
    @State private var barHSB: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
    
    var body: some View {
        PerformanceMonitor.shared.recordViewUpdate("EdgeVisualizerView")
        
        return Canvas { context, size in
            PerformanceMonitor.shared.start("Canvas_EdgeVisualizer_Draw")
            let centerX = thumbnailCenter?.x ?? size.width / 2
            let centerY = thumbnailCenter?.y ?? size.height / 2
            
            let bins = visualizerState.frequencyBins
            let bass = visualizerState.bassLevel
            guard bins.count >= 100 else { return }

            // Scale box to match thumbnail pulse
            let pulseScale = 1.0 + CGFloat(bass) * 0.20
            let boxSize = baseBoxSize * pulseScale
            let halfBox = boxSize / 2
            let scaledCorner = cornerRadius * pulseScale
            let straightEdge = boxSize - 2 * scaledCorner
            let spacing = straightEdge / CGFloat(barsPerSide)
            
            let hsb = barHSB
            let hasColors = hsb.count == 100
            
            var barIndex = 0
            
            // TOP (bins 0-24)
            for i in 0..<barsPerSide {
                let x = centerX - halfBox + scaledCorner + spacing * (CGFloat(i) + 0.5)
                let y = centerY - halfBox
                drawBarFast(context: context, x: x, y: y, dx: 0, dy: -1, value: bins[barIndex], hsb: hasColors ? hsb[barIndex] : nil)
                barIndex += 1
            }
            
            // RIGHT (bins 25-49)
            for i in 0..<barsPerSide {
                let x = centerX + halfBox
                let y = centerY - halfBox + scaledCorner + spacing * (CGFloat(i) + 0.5)
                drawBarFast(context: context, x: x, y: y, dx: 1, dy: 0, value: bins[barIndex], hsb: hasColors ? hsb[barIndex] : nil)
                barIndex += 1
            }
            
            // BOTTOM (bins 50-74)
            for i in 0..<barsPerSide {
                let x = centerX + halfBox - scaledCorner - spacing * (CGFloat(i) + 0.5)
                let y = centerY + halfBox
                drawBarFast(context: context, x: x, y: y, dx: 0, dy: 1, value: bins[barIndex], hsb: hasColors ? hsb[barIndex] : nil)
                barIndex += 1
            }
            
            // LEFT (bins 75-99)
            for i in 0..<barsPerSide {
                let x = centerX - halfBox
                let y = centerY + halfBox - scaledCorner - spacing * (CGFloat(i) + 0.5)
                drawBarFast(context: context, x: x, y: y, dx: -1, dy: 0, value: bins[barIndex], hsb: hasColors ? hsb[barIndex] : nil)
                barIndex += 1
            }
            
            PerformanceMonitor.shared.end("Canvas_EdgeVisualizer_Draw")
        }
        .drawingGroup()
        .onChange(of: audioPlayer.currentTrack) { newTrack in
            precomputeBarColors(for: newTrack)
        }
        .onAppear {
            precomputeBarColors(for: audioPlayer.currentTrack)
        }
    }
    
    /// ⚡ Pre-compute HSB base values for all 100 bars once per track change
    /// Eliminates 100× UIColor creation + HSB extraction per frame
    private func precomputeBarColors(for track: Track?) {
        guard let track = track else {
            barHSB = Array(repeating: (h: 0, s: 0, b: 1.0), count: 100) // white
            return
        }
        
        // Resolves both thumbnail schemes (legacy audio-filename key and the
        // current videoID key) instead of hand-building the legacy path.
        guard let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            barHSB = Array(repeating: (h: 0, s: 0, b: 1.0), count: 100)
            return
        }
        
        let dominantColors = extractDominantColors(from: image)
        
        // Pre-extract HSB for each bar position
        var result = [(h: CGFloat, s: CGFloat, b: CGFloat)]()
        result.reserveCapacity(100)
        
        for i in 0..<100 {
            let baseColor = dominantColors.isEmpty ? Color.white : dominantColors[i % dominantColors.count]
            let uiColor = UIColor(baseColor)
            var h: CGFloat = 0, s: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
            uiColor.getHue(&h, saturation: &s, brightness: &bri, alpha: &a)
            result.append((h: h, s: s, b: bri))
        }
        
        barHSB = result
    }
    
    private func extractDominantColors(from image: UIImage) -> [Color] {
        guard image.cgImage != nil else { return [Color.white] }
        
        // Resize to small size for performance
        let size = CGSize(width: 50, height: 50)
        UIGraphicsBeginImageContext(size)
        image.draw(in: CGRect(origin: .zero, size: size))
        guard let resizedImage = UIGraphicsGetImageFromCurrentImageContext(),
              let resizedCGImage = resizedImage.cgImage,
              let dataProvider = resizedCGImage.dataProvider,
              let pixelData = dataProvider.data,
              let data = CFDataGetBytePtr(pixelData) else {
            UIGraphicsEndImageContext()
            return [Color.white]
        }
        UIGraphicsEndImageContext()
        
        let bytesPerPixel = 4
        let bytesPerRow = resizedCGImage.bytesPerRow
        
        var colorCounts: [String: (color: Color, count: Int)] = [:]
        
        for y in stride(from: 0, to: 50, by: 2) {  // ⚡ Sample every other pixel
            for x in stride(from: 0, to: 50, by: 2) {
                let pixelIndex = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = CGFloat(data[pixelIndex]) / 255.0
                let g = CGFloat(data[pixelIndex + 1]) / 255.0
                let b = CGFloat(data[pixelIndex + 2]) / 255.0
                
                let brightness = (r + g + b) / 3.0
                guard brightness > 0.2 && brightness < 0.9 else { continue }
                
                let qR = Int(r * 4) / 4
                let qG = Int(g * 4) / 4
                let qB = Int(b * 4) / 4
                let key = "\(qR)-\(qG)-\(qB)"
                
                let color = Color(red: r, green: g, blue: b)
                if var existing = colorCounts[key] {
                    existing.count += 1
                    colorCounts[key] = existing
                } else {
                    colorCounts[key] = (color: color, count: 1)
                }
            }
        }
        
        let sortedColors = colorCounts.values
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0.color }
        
        return sortedColors.isEmpty ? [Color.white] : sortedColors
    }
    
    /// ⚡ Optimized drawBar — uses pre-computed HSB, no UIColor allocation per frame
    @inline(__always)
    private func drawBarFast(context: GraphicsContext, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, value: Float, hsb: (h: CGFloat, s: CGFloat, b: CGFloat)?) {
        guard value > 0.02 else { return }
        
        let normalizedValue = CGFloat(value)
        let barLength = normalizedValue * maxBarLength
        
        let finalColor: Color
        if let hsb = hsb {
            // Use pre-computed HSB — just apply intensity modulation (no UIColor allocation!)
            let hueShift = Double(normalizedValue) * 0.05 - 0.025
            let adjustedHue = (hsb.h + hueShift).truncatingRemainder(dividingBy: 1.0)
            let adjustedSaturation = min(1.0, max(0.7, hsb.s + Double(normalizedValue) * 0.3))
            let baseBrightness = max(0.5, hsb.b)
            let adjustedBrightness = min(1.0, baseBrightness + Double(normalizedValue) * 0.5)
            let opacity = 0.75 + Double(normalizedValue) * 0.25
            finalColor = Color(hue: adjustedHue, saturation: adjustedSaturation, brightness: adjustedBrightness, opacity: opacity)
        } else {
            let opacity = 0.75 + Double(normalizedValue) * 0.25
            finalColor = Color.white.opacity(opacity)
        }
        
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + dx * barLength, y: y + dy * barLength))
        
        let lineWidth = 2.5 + CGFloat(normalizedValue) * 1.5
        
        // Only draw glow on strong bars — saves ~60-70% of glow strokes
        if value > 0.35 {
            context.stroke(path, with: .color(finalColor.opacity(0.3)), style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round))
        }
        context.stroke(path, with: .color(finalColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}


// MARK: - Auto-Scrolling Text View
struct ScrollingTextView: View {
    let text: String
    let font: Font
    let width: CGFloat
    
    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 50) {
                // First instance
                Text(text)
                    .font(font)
                    .foregroundColor(Theme.bone)
                    .fixedSize()
                    .background(
                        GeometryReader { textGeo in
                            Color.clear.onAppear {
                                textWidth = textGeo.size.width
                            }
                        }
                    )
                
                // Second instance for seamless loop
                Text(text)
                    .font(font)
                    .foregroundColor(Theme.bone)
                    .fixedSize()
            }
            .offset(x: offset)
            .onAppear {
                startScrolling()
            }
        }
        .clipped()
    }
    
    private func startScrolling() {
        // Wait a moment before starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // Calculate duration based on text length (slower for longer text)
            let duration = Double(textWidth) / 30.0 // Adjust speed here (lower = faster)
            
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                // Scroll to the left by the full width + spacing
                offset = -(textWidth + 50)
            }
        }
    }
}

// MARK: - String Width Helper
extension String {
    func widthOfString(usingFont font: UIFont) -> CGFloat {
        let fontAttributes = [NSAttributedString.Key.font: font]
        let size = self.size(withAttributes: fontAttributes)
        return size.width
    }
}
