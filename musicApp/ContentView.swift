import SwiftUI
import AVFoundation
import MediaPlayer
import Accelerate

struct ContentView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var playlistManager = PlaylistManager()
    @State private var showFolderPicker = false
    @State private var showYouTubeDownload = false
    @State private var showNowPlaying = false
    // Now Playing slide position, owned here so the mini player can crossfade
    // with it (stay visible during the slide instead of vanishing instantly).
    @State private var nowPlayingOffset: CGFloat = UIScreen.main.bounds.height
    @State private var handlingDeepLink = false
    
    // For post-download playlist prompt
    @State private var playlistPromptDownload: Download? = nil
    
    init() {
        // Theme the UIKit-backed chrome (nav bars + tab bar) before first render.
        Theme.applyChrome()
    }
    
    var body: some View {
        PerformanceMonitor.shared.recordViewUpdate("ContentView")
        
        return ZStack(alignment: .bottom) {
            TabView {
                DownloadsView(
                    downloadManager: downloadManager,
                    playlistManager: playlistManager,
                    audioPlayer: audioPlayer,
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
                startFPSTracking()
                #if DEBUG
                MainThreadWatchdog.shared.start()
                #endif
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
                
                if audioPlayer.currentTrack != nil {
                    MiniPlayerBar(audioPlayer: audioPlayer, downloadManager: downloadManager, showNowPlaying: $showNowPlaying)
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
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @Binding var showNowPlaying: Bool
    @State private var backgroundImage: UIImage?
    
    private var progress: CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return CGFloat(min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1))
    }
    
    /// Resolve artwork the same way the lists do — through the Download
    /// record's stored thumbnail path — instead of guessing the filename
    /// from the audio URL. Falls back to the audio-derived path.
    private var currentThumbnailPath: String? {
        guard let track = audioPlayer.currentTrack else { return nil }
        if let stored = downloadManager.getDownload(byID: track.id)?.resolvedThumbnailPath,
           FileManager.default.fileExists(atPath: stored) {
            return stored
        }
        let derived = Artwork.thumbnailURL(forAudioFileURL: track.url).path
        return FileManager.default.fileExists(atPath: derived) ? derived : nil
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
                        thumbnailPath: currentThumbnailPath,
                        size: 42,
                        cornerRadius: 10
                    )
                    // The mini-player is a single persistent view, so its
                    // thumbnail keeps the same SwiftUI identity across songs and
                    // the previous track's async-loaded image lingers one song
                    // behind. Re-key on the track id to force a fresh load.
                    .id(audioPlayer.currentTrack?.id)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioPlayer.currentTrack?.name ?? "Unknown")
                            .font(Theme.body(15, weight: .semibold))
                            .lineLimit(1)
                            .foregroundColor(Theme.bone)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                        
                        Text((audioPlayer.currentTrack?.folderName ?? "").uppercased())
                            .font(Theme.eyebrowFont)
                            .tracking(1.2)
                            .foregroundColor(Theme.bone.opacity(0.7))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 2)
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
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(Theme.bone)
                        .frame(width: 36, height: 36)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .buttonStyle(.plain)
                
                Button {
                    audioPlayer.next()
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
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.emberGradient)
                    .frame(width: max(geo.size.width * progress, 0), height: 2.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.seam, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            updateBackgroundImage()
        }
        .onAppear {
            updateBackgroundImage()
        }
    }
    
    private func updateBackgroundImage() {
        guard let track = audioPlayer.currentTrack else {
            backgroundImage = nil
            return
        }
        
        let audioURL = track.url
        let path = currentThumbnailPath
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
                if self.audioPlayer.currentTrack?.url == audioURL {
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
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var localSeekPosition: Double = 0
    @State private var showPlaylistPicker = false
    @State private var backgroundImage: UIImage?
    @State private var showRenameAlert = false
    @State private var newTrackName: String = ""
    @State private var showAudioSettings = false
    @State private var showCropSheet = false
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
        .alert("Rename Song", isPresented: $showRenameAlert) {
            TextField("Song name", text: $newTrackName)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let track = audioPlayer.currentTrack,
                let download = downloadManager.downloads.first(where: { $0.url == track.url }) {
                    downloadManager.renameDownload(download, newName: newTrackName)
                }
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
    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                animatedDismiss()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(CircleControlButtonStyle(diameter: 40, tint: Theme.bone))
            
            Spacer()
            
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
            
            Menu {
                Button(action: { showPlaylistPicker = true }) {
                    Label("Add to Playlist", systemImage: "plus")
                }
                Button(action: { showCropSheet = true }) {
                    Label("Crop Song", systemImage: "scissors")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Theme.bone)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.smokeRaised))
                    .overlay(Circle().strokeBorder(Theme.seam, lineWidth: 1))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        PulsingThumbnailView(
            visualizerState: audioPlayer.visualizerState,
            thumbnailImage: getThumbnailImage(for: audioPlayer.currentTrack),
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
        }
        .padding(.bottom, 12)
    }
    
    @ViewBuilder
    private var titleView: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let titleText = audioPlayer.currentTrack?.name ?? "Unknown"
                let textWidth = titleText.widthOfString(usingFont: Theme.roundedUIFont(size: 28, weight: .heavy))
                let needsScroll = textWidth > geometry.size.width
                
                ZStack {
                    if needsScroll {
                        ScrollingTextView(
                            text: titleText,
                            font: Theme.display(28),
                            width: geometry.size.width
                        )
                    } else {
                        Text(titleText)
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
            
            Slider(value: sliderBinding, in: 0...max(audioPlayer.duration, 1)) { editing in
                isSeeking = editing
                if editing {
                    localSeekPosition = audioPlayer.currentTime
                } else {
                    audioPlayer.seek(to: localSeekPosition)
                }
            }
            .tint(Theme.redLight)
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
        .padding(.top, 22)
    }
    
    private func updateBackgroundImage() {
        guard let track = audioPlayer.currentTrack else {
            backgroundImage = nil
            return
        }
        
        // Screen-aspect crop for the full-screen backdrop
        let screenAspect = UIScreen.main.bounds.width / UIScreen.main.bounds.height
        backgroundImage = Artwork.croppedBackground(forAudioFileURL: track.url, aspect: screenAspect)
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
                                Slider(value: speedBinding, in: 0.5...2.0)
                                    .tint(speedColor)
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
                                Slider(value: pitchBinding, in: -12...12)
                                    .tint(pitchColor)
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
                                Slider(value: $audioPlayer.reverbAmount, in: 0...100)
                                    .tint(reverbColor)
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
                                Slider(value: $audioPlayer.bassBoost, in: -10...20)
                                    .tint(bassColor)
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
                        .font(Theme.body(15, weight: .semibold))
                        .foregroundColor(Theme.emberLight)
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
                    .font(Theme.caption(12, weight: .semibold))
                    .foregroundColor(color)
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
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(Theme.emberLight)
                        
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
        
        let filename = track.url.lastPathComponent.replacingOccurrences(of: ".mp3", with: "")
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
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


// MARK: - AppDelegate for orientation lock
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
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
