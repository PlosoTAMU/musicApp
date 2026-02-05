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
            NowPlayingView(audioPlayer: audioPlayer, isPresented: $showNowPlaying)
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
                Button {
                    showNowPlaying = true
                } label: {
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
                    }
                }
                .buttonStyle(.plain)
                
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
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var localSeekPosition: Double = 0
    @State private var showPlaylistPicker = false
    @State private var backgroundImage: UIImage?
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
    private var speedBinding: Binding<Double> {
        Binding(
            get: { audioPlayer.playbackSpeed },
            set: { newValue in
                let rounded = (newValue * 10).rounded() / 10
                audioPlayer.playbackSpeed = rounded
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
            
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 6) {
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
                    
                    // ✅ NEW: Loop button outside the menu
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            audioPlayer.isLoopEnabled.toggle()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isLoopEnabled ? "repeat.1" : "repeat")
                            .font(.title3)
                            .foregroundColor(audioPlayer.isLoopEnabled ? .blue : .white)
                            .frame(width: 44, height: 44)
                            .scaleEffect(audioPlayer.isLoopEnabled ? 1.1 : 1.0)
                            .rotationEffect(.degrees(audioPlayer.isLoopEnabled ? 360 : 0))
                    }
                    
                    Menu {
                        // ✅ REMOVED: Loop button (now outside)
                        
                        Divider()
                        
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
                
                Spacer()
                
                // Single container - no frame constraints, let it bleed
                ZStack {
                    // Main thumbnail with bass pulse (bottom layer)
                    Group {
                        if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                            Image(uiImage: thumbnailImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 220, height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.8), radius: 25, y: 8)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(LinearGradient(
                                    colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 220, height: 220)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 60))
                                        .foregroundColor(.white.opacity(0.5))
                                )
                                .shadow(color: .black.opacity(0.8), radius: 25, y: 8)
                        }
                    }
                    .scaleEffect(1.0 + CGFloat(audioPlayer.bassLevel) * 0.20)  // Punchier pulse
                    .zIndex(1)  // Thumbnail in middle
                    
                    // Visualizer overlay (top layer - always visible)
                    EdgeVisualizerView(audioPlayer: audioPlayer)
                        .allowsHitTesting(false)
                        .zIndex(2)  // Visualizer on top
                }
                .frame(minWidth: 320, minHeight: 320)  // Minimum size, can expand
                .compositingGroup()  // Group for better rendering
                .onTapGesture {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                }
                
                Spacer()
                
                VStack(spacing: 6) {
                    // ✅ NEW: Auto-scrolling title with continuous loop
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
                    }
                    .frame(height: 40)
                    .padding(.horizontal, 28)
                    
                    Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                    // ✅ NEW: Horizontally scrollable title
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(audioPlayer.currentTrack?.name ?? "Unknown")
                                .font(.title)
                                .fontWeight(.bold)
                                .italic()
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minWidth: geometry.size.width, alignment: .center)
                                .onTapGesture {
                                    if audioPlayer.isPlaying {
                                        audioPlayer.pause()
                                    } else {
                                        audioPlayer.resume()
                                    }
                                }
                        }
                        .frame(height: 40)
                    }
                    .frame(height: 40)
                    .padding(.horizontal, 28)
                    
                    Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                
                
                VStack(spacing: 2) {
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
                .onAppear {
                    seekValue = audioPlayer.currentTime
                }
                
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
                .padding(.top, 2)
                
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20)
                        Slider(value: speedBinding, in: 0.5...2.0)
                            .accentColor(.white)
                        Text(String(format: "%.1fx", audioPlayer.playbackSpeed))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 40)
                    }
                    
                    HStack(spacing: 10) {
                        Image(systemName: "waveform.path")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20)
                        Slider(value: $audioPlayer.reverbAmount, in: 0...100)
                            .accentColor(.white)
                        Text("\(Int(audioPlayer.reverbAmount))%")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 40)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
                
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
                .padding(.top, 16)
                .padding(.bottom, 28)
                
                Spacer()
            }
        }
        .onAppear {
            updateBackgroundImage()
            lockOrientation(.portrait)
        }
        .onDisappear {
            unlockOrientation()
        }
        .onChange(of: audioPlayer.currentTrack?.id) { _ in
            updateBackgroundImage()
        }
        .gesture(
            DragGesture()
                .onEnded { value in
                    if value.translation.height > 100 {
                        isPresented = false
                    }
                }
        )
        .sheet(isPresented: $showPlaylistPicker) {
            Text("Playlist picker coming soon")
                .padding()
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
              let thumbnailPath = EmbeddedPython.shared.getThumbnailPath(for: track.url),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            return nil
        }
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
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsVolumeSlider = true
        // Hide the route button by setting frame
        for subview in volumeView.subviews {
            if subview is UIButton {
                subview.isHidden = true
            }
        }
    
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.minimumTrackTintColor = .white
                slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
                slider.isContinuous = true
                
                let thumbSize: CGFloat = 14
                let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
                    UIColor.white.setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
                }
                slider.setThumbImage(thumbImage, for: .normal)
                slider.setThumbImage(thumbImage, for: .highlighted)
            }
        }
        
        return volumeView
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
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


// MARK: - Edge Visualizer (Beat-synced with dynamic range)
struct EdgeVisualizerView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    
    // Geometry - matches thumbnail with subtle pulse
    private let baseBoxSize: CGFloat = 220
    private let cornerRadius: CGFloat = 16
    private let maxBarLength: CGFloat = 60
    private let minBarLength: CGFloat = 1   // Lower minimum for larger dynamic range
    private let barsPerSide = 25  // 100 total bars = matches FFT bins
    
    @State private var dominantColors: [Color] = []
    
    var body: some View {
        Canvas { context, size in
            let centerX = size.width / 2
            let centerY = size.height / 2
            
            let bins = audioPlayer.frequencyBins
            let bass = audioPlayer.bassLevel
            guard bins.count >= 100 else { return }
            
            // Scale box to match thumbnail pulse
            // Bass level is now 0.05-0.9 range, map to punchier pulse
            let pulseScale = 1.0 + CGFloat(bass) * 0.20
            let boxSize = baseBoxSize * pulseScale
            let halfBox = boxSize / 2
            let scaledCorner = cornerRadius * pulseScale
            let straightEdge = boxSize - 2 * scaledCorner
            let spacing = straightEdge / CGFloat(barsPerSide)
            
            var barIndex = 0
            
            // TOP (bins 0-24)
            for i in 0..<barsPerSide {
                let x = centerX - halfBox + scaledCorner + spacing * (CGFloat(i) + 0.5)
                let y = centerY - halfBox
                drawBar(context: context, x: x, y: y, dx: 0, dy: -1, value: bins[barIndex], index: barIndex, colors: dominantColors)
                barIndex += 1
            }
            
            // RIGHT (bins 25-49)
            for i in 0..<barsPerSide {
                let x = centerX + halfBox
                let y = centerY - halfBox + scaledCorner + spacing * (CGFloat(i) + 0.5)
                drawBar(context: context, x: x, y: y, dx: 1, dy: 0, value: bins[barIndex], index: barIndex, colors: dominantColors)
                barIndex += 1
            }
            
            // BOTTOM (bins 50-74)
            for i in 0..<barsPerSide {
                let x = centerX + halfBox - scaledCorner - spacing * (CGFloat(i) + 0.5)
                let y = centerY + halfBox
                drawBar(context: context, x: x, y: y, dx: 0, dy: 1, value: bins[barIndex], index: barIndex, colors: dominantColors)
                barIndex += 1
            }
            
            // LEFT (bins 75-99)
            for i in 0..<barsPerSide {
                let x = centerX - halfBox
                let y = centerY + halfBox - scaledCorner - spacing * (CGFloat(i) + 0.5)
                drawBar(context: context, x: x, y: y, dx: -1, dy: 0, value: bins[barIndex], index: barIndex, colors: dominantColors)
                barIndex += 1
            }
        }
        .drawingGroup()
        .onChange(of: audioPlayer.currentTrack) { newTrack in
            updateColors(for: newTrack)
        }
        .onAppear {
            updateColors(for: audioPlayer.currentTrack)
        }
    }
    
    private func updateColors(for track: Track?) {
        guard let track = track else {
            dominantColors = [Color.white]
            return
        }
        
        let filename = track.url.lastPathComponent.replacingOccurrences(of: ".mp3", with: "")
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let image = UIImage(contentsOfFile: thumbnailPath.path) else {
            dominantColors = [Color.white]
            return
        }
        
        dominantColors = extractDominantColors(from: image)
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
        
        // Sample colors from the image
        var colorCounts: [String: (color: Color, count: Int)] = [:]
        
        for y in 0..<50 {
            for x in 0..<50 {
                let pixelIndex = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = CGFloat(data[pixelIndex]) / 255.0
                let g = CGFloat(data[pixelIndex + 1]) / 255.0
                let b = CGFloat(data[pixelIndex + 2]) / 255.0
                
                // Skip very dark or very light colors
                let brightness = (r + g + b) / 3.0
                guard brightness > 0.2 && brightness < 0.9 else { continue }
                
                // Quantize to reduce similar colors
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
        
        // Get top 3 most common colors
        let sortedColors = colorCounts.values
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { $0.color }
        
        return sortedColors.isEmpty ? [Color.white] : sortedColors
    }
    
    @inline(__always)
    private func drawBar(context: GraphicsContext, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat, value: Float, index: Int, colors: [Color]) {
        // Values now range 0-1 from AudioPlayerManager
        // 0 = no activity, line should not be drawn
        guard value > 0.01 else { return }  // Skip near-zero values
        
        let normalizedValue = CGFloat(value)
        
        // Calculate bar length - 0 means invisible, 1 means full length
        let barLength = normalizedValue * maxBarLength
        
        // Choose color from extracted palette based on position and intensity
        let baseColor: Color
        if colors.isEmpty {
            baseColor = Color.white
        } else {
            // Cycle through the dominant colors based on position
            let colorIndex = index % colors.count
            baseColor = colors[colorIndex]
        }
        
        // Extract HSB from base color and modify for visual interest
        let uiColor = UIColor(baseColor)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        
        // Shift hue slightly based on intensity for variation
        let hueShift = Double(normalizedValue) * 0.05 - 0.025  // ±2.5% hue shift
        let adjustedHue = (hue + hueShift).truncatingRemainder(dividingBy: 1.0)
        
        // Ensure lines are always bright and saturated enough to be visible
        // Boost saturation significantly
        let adjustedSaturation = min(1.0, max(0.7, saturation + Double(normalizedValue) * 0.3))
        
        // Ensure minimum brightness so lines are always visible (even if thumbnail is dark)
        let baseBrightness = max(0.5, brightness)  // At least 50% brightness
        let adjustedBrightness = min(1.0, baseBrightness + Double(normalizedValue) * 0.5)
        
        // Higher opacity for better visibility
        let opacity = 0.75 + Double(normalizedValue) * 0.25
        
        let finalColor = Color(hue: adjustedHue, saturation: adjustedSaturation, brightness: adjustedBrightness, opacity: opacity)
        
        var path = Path()
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + dx * barLength, y: y + dy * barLength))
        
        // Line width pulses with intensity - slightly thicker for visibility
        let lineWidth = 2.5 + CGFloat(normalizedValue) * 1.5
        
        // Add glow effect for better visibility against dark backgrounds
        context.stroke(path, with: .color(finalColor.opacity(0.3)), style: StrokeStyle(lineWidth: lineWidth + 2, lineCap: .round))
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