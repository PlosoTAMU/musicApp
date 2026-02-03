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
    @State private var thumbnailPulse: CGFloat = 1.0  // ADD THIS

    
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
                    
                    Menu {
                        Button(action: { 
                            audioPlayer.isLoopEnabled.toggle()
                        }) {
                            Label(
                                audioPlayer.isLoopEnabled ? "Loop: On" : "Loop: Off",
                                systemImage: audioPlayer.isLoopEnabled ? "repeat.1" : "repeat"
                            )
                        }
                        
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
                .padding(.top, 35)
                
                Spacer()
                
                ZStack {
                    // Main thumbnail - PULSES with bass
                    Group {
                        if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                            Image(uiImage: thumbnailImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 290, height: 290)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .shadow(color: .black.opacity(0.8), radius: 30, y: 10)
                        } else {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(LinearGradient(
                                    colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 290, height: 290)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 80))
                                        .foregroundColor(.white.opacity(0.5))
                                )
                                .shadow(color: .black.opacity(0.8), radius: 30, y: 10)
                        }
                    }
                    .scaleEffect(thumbnailPulse)  // Thumbnail pulses!
                    
                    // Visualizer overlay - ALWAYS visible, lines extend outward
                    EdgeVisualizerView(audioPlayer: audioPlayer, thumbnailPulse: $thumbnailPulse)
                        .frame(width: 390, height: 390)  // Larger to fit outward lines
                        .allowsHitTesting(false)
                }
                .frame(width: 390, height: 390)  // Fixed frame prevents layout shifts
                .onTapGesture {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                }
                
                Spacer()
                
                VStack(spacing: 6) {
                    Text(audioPlayer.currentTrack?.name ?? "Unknown")
                        .font(.title)
                        .fontWeight(.bold)
                        .italic()
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .onTapGesture {
                            if audioPlayer.isPlaying {
                                audioPlayer.pause()
                            } else {
                                audioPlayer.resume()
                            }
                        }
                    
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


// MARK: - Edge Visualizer (Matches HTML exactly)
struct EdgeVisualizerView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var thumbnailPulse: CGFloat
    
    // Visualization state
    @State private var lineAmplitudes: [CGFloat] = Array(repeating: 0, count: 200)
    @State private var currentPulse: CGFloat = 1.0
    @State private var lineGroups: [Bool] = (0..<200).map { _ in Float.random(in: 0...1) > 0.7 }
    
    // Match HTML constants exactly
    private let segments = 200
    private let smoothingFactor: CGFloat = 0.4
    private let threshold: CGFloat = 0.1
    private let strengthMultiplier: CGFloat = 3.5
    private let power: CGFloat = 0.2
    private let maxOut: CGFloat = 50  // Longer lines
    private let bassThreshold: CGFloat = 0.1
    private let bassMultiplier: CGFloat = 0.6
    private let pulseSmooth: CGFloat = 0.45
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0/60.0)) { timeline in
            Canvas { context, size in
                let centerX = size.width / 2
                let centerY = size.height / 2
                
                // Box matches thumbnail (290x290, 20 corner radius)
                // But we need to account for lines extending outward
                let boxSize: CGFloat = 290
                let radius: CGFloat = 20
                
                let baseX = centerX - boxSize / 2
                let baseY = centerY - boxSize / 2
                
                // Calculate perimeter
                let straightEdge = boxSize - 2 * radius
                let cornerArc = (.pi / 2) * radius
                let totalPerimeter = 4 * straightEdge + 4 * cornerArc
                
                // Draw lines extending outward
                for i in 0..<segments {
                    var amplitude = lineAmplitudes[i]
                    
                    // Apply group B multiplier (2/3 amplitude) like HTML
                    if i < lineGroups.count && lineGroups[i] {
                        amplitude *= 0.6666666666666666
                    }
                    
                    // Skip very small amplitudes
                    if amplitude < 2 { continue }
                    
                    let distance = (CGFloat(i) / CGFloat(segments)) * totalPerimeter
                    var x: CGFloat = 0
                    var y: CGFloat = 0
                    var nx: CGFloat = 0
                    var ny: CGFloat = 0
                    var isCorner = false
                    
                    // Top edge
                    if distance < straightEdge {
                        x = baseX + radius + distance
                        y = baseY
                        nx = 0
                        ny = -1
                    }
                    // Top-right corner
                    else if distance < straightEdge + cornerArc {
                        isCorner = true
                    }
                    // Right edge
                    else if distance < 2 * straightEdge + cornerArc {
                        x = baseX + boxSize
                        y = baseY + radius + (distance - straightEdge - cornerArc)
                        nx = 1
                        ny = 0
                    }
                    // Bottom-right corner
                    else if distance < 2 * straightEdge + 2 * cornerArc {
                        isCorner = true
                    }
                    // Bottom edge
                    else if distance < 3 * straightEdge + 2 * cornerArc {
                        x = baseX + boxSize - radius - (distance - 2 * straightEdge - 2 * cornerArc)
                        y = baseY + boxSize
                        nx = 0
                        ny = 1
                    }
                    // Bottom-left corner
                    else if distance < 3 * straightEdge + 3 * cornerArc {
                        isCorner = true
                    }
                    // Left edge
                    else if distance < 4 * straightEdge + 3 * cornerArc {
                        x = baseX
                        y = baseY + boxSize - radius - (distance - 3 * straightEdge - 3 * cornerArc)
                        nx = -1
                        ny = 0
                    }
                    // Top-left corner
                    else {
                        isCorner = true
                    }
                    
                    if isCorner { continue }
                    
                    // Rainbow gradient (matching HTML: hue offset by 180)
                    let t = CGFloat(i) / CGFloat(segments)
                    let hue = (t * 360 + 180).truncatingRemainder(dividingBy: 360) / 360.0
                    let opacity = 0.6 + (amplitude / maxOut) * 0.4
                    
                    let color = Color(hue: hue, saturation: 1.0, brightness: 0.6).opacity(opacity)
                    
                    // Draw line from edge outward
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + nx * amplitude, y: y + ny * amplitude))
                    
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                }
            }
            .onChange(of: timeline.date) { _ in
                updateVisualization()
            }
        }
    }
    
    private func updateVisualization() {
        let time = Date().timeIntervalSince1970
        
        if audioPlayer.isPlaying {
            // Simulate bass from multiple sine waves (like real audio)
            let bassWave1 = sin(time * 8.0) * 0.5 + 0.5
            let bassWave2 = sin(time * 3.7) * 0.3 + 0.7
            let bassWave3 = sin(time * 12.1) * 0.2 + 0.8
            let bass = Float(bassWave1 * bassWave2 * bassWave3 * 0.25)
            
            // Calculate pulse from bass (matching HTML exactly)
            let bassPulse = bass > Float(bassThreshold) ?
                CGFloat((bass - Float(bassThreshold)) / 0.9) : 0
            let targetPulse = 1.0 + bassPulse * bassMultiplier
            currentPulse += (targetPulse - currentPulse) * pulseSmooth
            
            // Update thumbnail pulse binding
            thumbnailPulse = currentPulse
            
            // Update line amplitudes with varied frequencies per segment
            for i in 0..<segments {
                let phase1 = time * 10.0 + Double(i) * 0.12
                let phase2 = time * 6.3 + Double(i) * 0.19
                let phase3 = time * 3.7 + Double(i) * 0.27
                
                // Combine multiple frequencies for organic look
                let wave = sin(phase1) * 0.35 + sin(phase2) * 0.4 + sin(phase3) * 0.25
                let rawStrength = abs(Float(wave))
                
                var strength: CGFloat = 0
                
                if rawStrength > Float(threshold) {
                    let normalized = CGFloat((rawStrength - Float(threshold)) / 0.9)
                    strength = pow(normalized, power) * strengthMultiplier
                }
                
                // Smooth transition (matching HTML smoothingFactor)
                let targetOut = strength * maxOut
                lineAmplitudes[i] += (targetOut - lineAmplitudes[i]) * smoothingFactor
                
                // Minimum threshold
                if lineAmplitudes[i] < 2 {
                    lineAmplitudes[i] = 0
                }
            }
        } else {
            // When paused: decay all values smoothly
            thumbnailPulse += (1.0 - thumbnailPulse) * 0.1
            currentPulse += (1.0 - currentPulse) * 0.1
            
            for i in 0..<segments {
                lineAmplitudes[i] *= 0.92  // Smooth decay
                if lineAmplitudes[i] < 1 {
                    lineAmplitudes[i] = 0
                }
            }
        }
    }
}



// MARK: - AppDelegate for orientation lock
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.all
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}