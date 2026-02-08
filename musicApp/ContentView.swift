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
    
    var body: some View {
        ZStack(alignment: .bottom) {
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
            }
            
            VStack(spacing: 0) {
                Spacer()
                
                if !downloadManager.activeDownloads.isEmpty {
                    DownloadBanner(downloadManager: downloadManager)
                        .padding(.bottom, 8)
                }
                
                if audioPlayer.currentTrack != nil {
                    MiniPlayerBar(audioPlayer: audioPlayer, showNowPlaying: $showNowPlaying)
                }
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(
                audioPlayer: audioPlayer,
                downloadManager: downloadManager,
                playlistManager: playlistManager,
                isPresented: $showNowPlaying
            )
            .statusBarHidden(false)
            .persistentSystemOverlays(.hidden)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
        // FIXED: Close now playing when playback ends
        .onAppear {
            // Set up the reference so DownloadManager can update playing tracks
            downloadManager.audioPlayer = audioPlayer
            
            
            processIncomingShares()
            
            // FIXED: Close now playing when playback ends
            audioPlayer.onPlaybackEnded = {
                showNowPlaying = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            processIncomingShares()
        }
        .onOpenURL { url in
            print("📥 App opened with URL: \(url)")
            handleIncomingURL(url)
        }

        
    }

    // ✅ ADD: FPS tracking with CADisplayLink
    private func startFPSTracking() {
        let displayLink = CADisplayLink(target: FPSTracker.shared, selector: #selector(FPSTracker.tick))
        displayLink.add(to: .main, forMode: .common)
    }

    // ✅ ADD: FPS tracker class
    class FPSTracker {
        static let shared = FPSTracker()
        private var lastTimestamp: CFTimeInterval = 0
        
        @objc func tick(displayLink: CADisplayLink) {
            if lastTimestamp > 0 {
                let fps = 1.0 / (displayLink.timestamp - lastTimestamp)
                PerformanceMonitor.shared.recordFrame()
            }
            lastTimestamp = displayLink.timestamp
        }
    }

    private func handleIncomingURL(_ url: URL) {
        print("📥 App opened with URL: \(url)")
        
        let urlString = url.absoluteString
        
        // Handle custom scheme (from Share Extension) - don't process, let queue drain handle it
        if url.scheme == "musicApp" || url.scheme == "pulsor" {
            print("📥 Deep link detected, queue will be processed on appear")
            return
        }
        
        // Handle direct YouTube/Spotify URLs (not from Share Extension)
        if urlString.contains("youtube.com") || urlString.contains("youtu.be") {
            startDownload(from: urlString, source: .youtube)
        } else if urlString.contains("spotify.com") || urlString.contains("open.spotify.com") {
            startDownload(from: urlString, source: .spotify)
        }
    }

    // ✅ FIXED: New helper method with proper source detection
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
                title: detectedSource == .spotify ? "Converting Spotify..." : "Downloading..."
            )
        } else {
            print("⚠️ Skipping duplicate: \(videoID)")
        }
    }
    
    // ✅ FIXED: Process shared URLs with proper source detection
    private func processIncomingShares() {
        let urls = IncomingShareQueue.drain()
        
        guard !urls.isEmpty else { return }
        
        print("📥 Processing \(urls.count) shared URLs")
        
        for urlString in urls {
            // ✅ FIXED: Use extractVideoID that returns (source, id)
            guard let (source, videoID) = Self.extractVideoID(from: urlString) else {
                print("⚠️ Invalid URL format: \(urlString)")
                continue
            }
            
            // Check for duplicates
            if downloadManager.findDuplicateByVideoID(videoID: videoID, source: source) != nil {
                print("⚠️ Skipping duplicate: \(videoID)")
                continue
            }
            
            // ✅ FIXED: Pass source parameter
            downloadManager.startBackgroundDownload(
                url: urlString,
                videoID: videoID,
                source: source,
                title: source == .spotify ? "Converting Spotify..." : "Downloading..."
            )
        }
    }
    

    // ✅ FIXED: Updated to return (DownloadSource, String) tuple
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
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    @State private var backgroundImage: UIImage?
    
    var body: some View {
        ZStack {
            // FIXED: Blurred background like NowPlayingView
            if let bgImage = backgroundImage {
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 65)
                    .blur(radius: 30)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.2)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 65)
            }
            
            // Darkening overlay for readability
            Color.black.opacity(0.3)
                .frame(height: 65)
            
            HStack(spacing: 12) {
                // Left side - thumbnail and text (fully tappable)
                HStack(spacing: 12) {
                    ZStack {
                        if let thumbnailPath = getThumbnailImage(for: audioPlayer.currentTrack) {
                            Image(uiImage: thumbnailPath)
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
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioPlayer.currentTrack?.name ?? "Unknown")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                        
                        Text(audioPlayer.currentTrack?.folderName ?? "")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture {
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
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .buttonStyle(.plain)
                
                Button {
                    audioPlayer.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
        .padding(.bottom, 49)
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
        
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let filename = track.url.lastPathComponent
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let originalImage = UIImage(contentsOfFile: thumbnailPath.path) else {
            backgroundImage = nil
            return
        }
        
        // Crop to fit mini player aspect ratio (wide)
        let targetAspect: CGFloat = 4.0 // Wide aspect for mini player
        let imageAspect = originalImage.size.width / originalImage.size.height
        
        var cropRect: CGRect
        if imageAspect > targetAspect {
            let newWidth = originalImage.size.height * targetAspect
            let x = (originalImage.size.width - newWidth) / 2
            cropRect = CGRect(x: x, y: 0, width: newWidth, height: originalImage.size.height)
        } else {
            let newHeight = originalImage.size.width / targetAspect
            let y = (originalImage.size.height - newHeight) / 2
            cropRect = CGRect(x: 0, y: y, width: originalImage.size.width, height: newHeight)
        }
        
        if let cgImage = originalImage.cgImage?.cropping(to: cropRect) {
            backgroundImage = UIImage(cgImage: cgImage)
        } else {
            backgroundImage = originalImage
        }
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track else { return nil }
        
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let filename = track.url.lastPathComponent
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            return nil
        }
        return image
    }
}

// MARK: - Full Now Playing View
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var playlistManager: PlaylistManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var localSeekPosition: Double = 0
    @State private var showPlaylistPicker = false
    @State private var backgroundImage: UIImage?
    @State private var showRenameAlert = false
    @State private var newTrackName: String = ""
    @State private var showAudioSettings = false
    @State private var thumbnailCenter: CGPoint = .zero
    // ✅ REMOVED: thumbnailPulse state - now using audioPlayer.pulse directly

    
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
    
    // ✅ NEW: Calculate current progress for waveform highlighting
    private var playbackProgress: CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return CGFloat(audioPlayer.currentTime / audioPlayer.duration)
    }
    
    var body: some View {
        ZStack {
            backgroundLayer
            
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                topBar
                
                Spacer(minLength: 5)
                
                thumbnailView
                
                Spacer(minLength: 15)
                
                controlsSection
            }
            
            // Visualizer layer
            EdgeVisualizerView(audioPlayer: audioPlayer, visualizerState: audioPlayer.visualizerState, thumbnailCenter: thumbnailCenter)
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        }
        .onAppear {
            updateBackgroundImage()
            lockOrientation(.portrait)
            audioPlayer.startVisualization()
        }
        .onDisappear {
            unlockOrientation()
            audioPlayer.stopVisualization()
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            updateBackgroundImage()
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 100 {
                        isPresented = false
                    } else if value.translation.height < -100 {
                        showAudioSettings = true
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
        if let bgImage = backgroundImage {
            Image(uiImage: bgImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                .blur(radius: 50)
                .scaleEffect(1.3)
                .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }
    
    @ViewBuilder
    private var topBar: some View {
        HStack {
            Button {
                isPresented = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            
            Spacer()
            
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    audioPlayer.isLoopEnabled.toggle()
                }
            } label: {
                Image(systemName: "repeat")
                    .font(.title3)
                    .foregroundColor(audioPlayer.isLoopEnabled ? .blue : .white)
                    .frame(width: 44, height: 44)
                    .scaleEffect(audioPlayer.isLoopEnabled ? 1.1 : 1.0)
                    .rotationEffect(.degrees(audioPlayer.isLoopEnabled ? 360 : 0))
            }
            
            Button {
                audioPlayer.effectsBypass.toggle()
            } label: {
                Image(systemName: "slider.vertical.3")
                    .font(.title3)
                    .foregroundColor(audioPlayer.effectsBypass ? .white : .blue)
                    .frame(width: 44, height: 44)
            }
            
            Menu {
                Button(action: { showPlaylistPicker = true }) {
                    Label("Add to Playlist", systemImage: "plus")
                }
                Button(action: {}) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40)
    }
    
    @ViewBuilder
    private var thumbnailView: some View {
        PulsingThumbnailView(
            visualizerState: audioPlayer.visualizerState,
            thumbnailImage: getThumbnailImage(for: audioPlayer.currentTrack),
            onThumbnailCenterChanged: { newCenter in
                thumbnailCenter = newCenter
            },
            onTap: {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            }
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
        .padding(.bottom, 65)
    }
    
    @ViewBuilder
    private var titleView: some View {
        GeometryReader { geometry in
            let titleText = audioPlayer.currentTrack?.name ?? "Unknown"
            let textWidth = titleText.widthOfString(usingFont: UIFont.boldSystemFont(ofSize: 28))
            let needsScroll = textWidth > geometry.size.width
            
            ZStack {
                if needsScroll {
                    ScrollingTextView(
                        text: titleText,
                        font: .title,
                        width: geometry.size.width
                    )
                } else {
                    Text(titleText)
                        .font(.title)
                        .fontWeight(.bold)
                        .italic()
                        .foregroundColor(.white)
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
        .padding(.horizontal, 28)
    }
    
    @ViewBuilder
    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                
                Text("-" + formatTime((audioPlayer.duration - (isSeeking ? localSeekPosition : audioPlayer.currentTime)) / audioPlayer.playbackSpeed))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            
            Slider(value: sliderBinding, in: 0...max(audioPlayer.duration, 1)) { editing in
                isSeeking = editing
                if editing {
                    localSeekPosition = audioPlayer.currentTime
                } else {
                    audioPlayer.seek(to: localSeekPosition)
                }
            }
            .accentColor(.white)
            .disabled(audioPlayer.duration == 0)
            
            HStack {
                Text(formatTime(isSeeking ? localSeekPosition : audioPlayer.currentTime))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                
                Spacer()
                
                Text(formatTime(audioPlayer.duration))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .onAppear {
            seekValue = audioPlayer.currentTime
        }
    }
    
    @ViewBuilder
    private var playbackControls: some View {
        HStack(spacing: 16) {
            Button { audioPlayer.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
            }
            
            RewindButton(audioPlayer: audioPlayer)
            
            Button {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 76))
                    .foregroundColor(.white)
            }
            
            FastForwardButton(audioPlayer: audioPlayer)
            
            Button { audioPlayer.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
                    .frame(width: 50, height: 50)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }
    
    @ViewBuilder
    private var volumeBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
            VolumeSlider()
                .frame(height: 20)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
        }
        .padding(.horizontal, 36)
        .padding(.top, 25)
    }
    
    
    private func updateBackgroundImage() {
        guard let track = audioPlayer.currentTrack else {
            backgroundImage = nil
            return
        }
        
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let filename = track.url.lastPathComponent
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let originalImage = UIImage(contentsOfFile: thumbnailPath.path) else {
            backgroundImage = nil
            return
        }
        
        let screenAspect = UIScreen.main.bounds.width / UIScreen.main.bounds.height
        let imageAspect = originalImage.size.width / originalImage.size.height
        
        var cropRect: CGRect
        if imageAspect > screenAspect {
            let newWidth = originalImage.size.height * screenAspect
            let x = (originalImage.size.width - newWidth) / 2
            cropRect = CGRect(x: x, y: 0, width: newWidth, height: originalImage.size.height)
        } else {
            let newHeight = originalImage.size.width / screenAspect
            let y = (originalImage.size.height - newHeight) / 2
            cropRect = CGRect(x: 0, y: y, width: originalImage.size.width, height: newHeight)
        }
        
        if let cgImage = originalImage.cgImage?.cropping(to: cropRect) {
            backgroundImage = UIImage(cgImage: cgImage)
        } else {
            backgroundImage = originalImage
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track,
              let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url) else {
            return nil
        }
        
        let pathString = thumbnailPath.path
        
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
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
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
    @State private var speedBeforeFF: Double = 1.0
    
    var body: some View {
        Image("forward")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressTimer == nil {
                            pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                isLongPressing = true
                                speedBeforeFF = audioPlayer.playbackSpeed
                                audioPlayer.playbackSpeed = 2.0
                            }
                        }
                    }
                    .onEnded { _ in
                        pressTimer?.invalidate()
                        pressTimer = nil
                        
                        if isLongPressing {
                            audioPlayer.playbackSpeed = speedBeforeFF
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
        uiView.refreshStyling()
    }
}

class VolumeContainerView: UIView {
    private let volumeView = MPVolumeView()
    private var observer: NSKeyValueObservation?
    
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
        volumeView.showsRouteButton = false
        volumeView.translatesAutoresizingMaskIntoConstraints = false
        
        addSubview(volumeView)
        NSLayoutConstraint.activate([
            volumeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            volumeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            volumeView.topAnchor.constraint(equalTo: topAnchor),
            volumeView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        
        // Observe subview changes
        observer = volumeView.observe(\.subviews, options: [.new]) { [weak self] _, _ in
            self?.refreshStyling()
        }
        
        // Initial + delayed styling
        refreshStyling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.refreshStyling() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refreshStyling() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshStyling() }
    }
    
    func refreshStyling() {
        // Hide buttons
        volumeView.subviews
            .compactMap { $0 as? UIButton }
            .forEach { $0.isHidden = true; $0.alpha = 0 }
        
        // Style slider
        guard let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider else {
            return
        }
        
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.thumbTintColor = nil
        
        let thumb = makeThumb(size: 12)
        UIView.performWithoutAnimation {
            slider.setThumbImage(thumb, for: .normal)
            slider.setThumbImage(thumb, for: .highlighted)
        }
    }
    
    private func makeThumb(size: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        refreshStyling()  // Re-apply on layout changes
    }
}

// MARK: - Audio Settings Sheet
struct AudioSettingsSheet: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    
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
            ScrollView {
                VStack(spacing: 36) {
                    // Speed
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "gauge.with.needle")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            Text("Speed")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "%.1fx", audioPlayer.playbackSpeed))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        
                        Slider(value: speedBinding, in: 0.5...2.0)
                            .tint(.blue)
                        
                        HStack {
                            Text("0.5x")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset") {
                                audioPlayer.playbackSpeed = 1.0
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                            Spacer()
                            Text("2.0x")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Pitch
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "music.note")
                                .foregroundColor(.purple)
                                .frame(width: 24)
                            Text("Pitch")
                                .font(.headline)
                            Spacer()
                            Text(audioPlayer.pitchShift == 0 ? "0" : String(format: "%+.1f", audioPlayer.pitchShift))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                            Text("st")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: pitchBinding, in: -12...12)
                            .tint(.purple)
                        
                        HStack {
                            Text("-12")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset") {
                                audioPlayer.pitchShift = 0
                            }
                            .font(.caption)
                            .foregroundColor(.purple)
                            Spacer()
                            Text("+12")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Reverb
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "waveform.path")
                                .foregroundColor(.cyan)
                                .frame(width: 24)
                            Text("Reverb")
                                .font(.headline)
                            Spacer()
                            Text("\(Int(audioPlayer.reverbAmount))%")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        
                        Slider(value: $audioPlayer.reverbAmount, in: 0...100)
                            .tint(.cyan)
                        
                        HStack {
                            Text("0%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset") {
                                audioPlayer.reverbAmount = 0
                            }
                            .font(.caption)
                            .foregroundColor(.cyan)
                            Spacer()
                            Text("100%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Bass Boost
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            Text("Bass Boost")
                                .font(.headline)
                            Spacer()
                            Text(audioPlayer.bassBoost == 0 ? "0" : String(format: "%+.0f", audioPlayer.bassBoost))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                            Text("dB")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: $audioPlayer.bassBoost, in: -10...20)
                            .tint(.orange)
                        
                        HStack {
                            Text("-10")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Reset") {
                                audioPlayer.bassBoost = 0
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                            Spacer()
                            Text("+20")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 40)
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
                        .font(.subheadline)
                    }
                }
            }
        }
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
                        
                        Text("\(download.title)\(String(repeating: ".", count: dotCount))")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}


// MARK: - Pulsing Thumbnail (directly observes VisualizerState for 60fps sync)
struct PulsingThumbnailView: View {
    @ObservedObject var visualizerState: VisualizerState
    let thumbnailImage: UIImage?
    var onThumbnailCenterChanged: ((CGPoint) -> Void)?
    var onTap: (() -> Void)?
    
    var body: some View {
        Group {
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
                        colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 200, height: 200)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.5))
                    )
                    .shadow(color: .black.opacity(0.8), radius: 25, y: 8)
            }
        }
        .scaleEffect(1.0 + CGFloat(visualizerState.bassLevel) * 0.20)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        // Report center ONCE on layout — scaleEffect doesn't move the center
                        let frame = geo.frame(in: .global)
                        onThumbnailCenterChanged?(CGPoint(x: frame.midX, y: frame.midY))
                    }
            }
        )
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
        Canvas { context, size in
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
        guard let cgImage = image.cgImage else { return [Color.white] }
        
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
                    .fontWeight(.bold)
                    .italic()
                    .foregroundColor(.white)
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
                    .fontWeight(.bold)
                    .italic()
                    .foregroundColor(.white)
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