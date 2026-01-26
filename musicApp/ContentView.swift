import SwiftUI
import AVFoundation
import MediaPlayer

// MARK: - Main ContentView with TabView
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
            }
            
            if audioPlayer.currentTrack != nil {
                MiniPlayerBar(audioPlayer: audioPlayer, showNowPlaying: $showNowPlaying)
                    .transition(.move(edge: .bottom))
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(audioPlayer: audioPlayer, isPresented: $showNowPlaying)
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
        .overlay(alignment: .bottom) {
            if !downloadManager.activeDownloads.isEmpty {
                VStack {
                    Spacer()
                    DownloadBanner(downloadManager: downloadManager)
                        .padding(.bottom, audioPlayer.currentTrack != nil ? 120 : 65) // FIXED: Raised higher to avoid collision
                }
                .transition(.move(edge: .bottom))
            }
        }
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail and track info (tappable to open full view)
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
                            .foregroundColor(.primary)
                        
                        Text(audioPlayer.currentTrack?.folderName ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Play/Pause button
            Button {
                if audioPlayer.isPlaying {
                    audioPlayer.pause()
                } else {
                    audioPlayer.resume()
                }
            } label: {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            
            // Next button
            Button {
                audioPlayer.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 0.5),
            alignment: .top
        )
        .padding(.bottom, 49)  // Sit above tab bar
    }
    
    private func getThumbnailImage(for track: Track?) -> UIImage? {
        guard let track = track else { return nil }
        
        // Get thumbnail through file system
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

// MARK: - System Volume View
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.tintColor = .white
        return volumeView
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Rewind Button
struct RewindButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    
    var body: some View {
        Image("rewind")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
            .foregroundColor(.white)
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        isHolding = true
                        audioPlayer.startRewind()
                    }
                    .simultaneously(with: DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            if isHolding {
                                audioPlayer.resumeNormalSpeed()
                                isHolding = false
                            } else {
                                audioPlayer.skip(seconds: -10)
                            }
                        }
                    )
            )
    }
}

// MARK: - Fast Forward Button
struct FastForwardButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    
    var body: some View {
        Image("forward")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 24, height: 24)
            .foregroundColor(.white)
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .onEnded { _ in
                        isHolding = true
                        audioPlayer.startFastForward()
                    }
                    .simultaneously(with: DragGesture(minimumDistance: 0)
                        .onEnded { _ in
                            if isHolding {
                                audioPlayer.resumeNormalSpeed()
                                isHolding = false
                            } else {
                                audioPlayer.skip(seconds: 10)
                            }
                        }
                    )
            )
    }
}

// MARK: - Full Now Playing View (FIXED: Removed zoom, better spacing)
struct NowPlayingView: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isPresented: Bool
    @State private var isSeeking = false
    @State private var seekValue: Double = 0
    @State private var showPlaylistPicker = false
    @State private var isHoldingRewind = false
    @State private var isHoldingFF = false
    @State private var backgroundImage: UIImage?
    
    var body: some View {
        ZStack {
            // Cropped, blurred, and zoomed background
            if let bgImage = backgroundImage {
                Image(uiImage: bgImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
                    .blur(radius: 30)
                    .scaleEffect(1.2)
                    .ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            
            // Dark overlay for readability
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // FIXED: Top bar with proper safe area padding
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44) // FIXED: Larger tap target
                    
                    Spacer()
                    
                    Menu {
                        Button(action: { showPlaylistPicker = true }) {
                            Label("Add to Playlist", systemImage: "plus")
                        }
                        Button(action: {}) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44) // FIXED: Larger tap target
                }
                .padding(.horizontal, 20) // FIXED: More padding from edges
                .padding(.top, 8)
                
                Spacer()
                
                // Album artwork - tappable
                Button {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    ZStack {
                        if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                            Image(uiImage: thumbnailImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 280, height: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 280, height: 280)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 70))
                                        .foregroundColor(.white.opacity(0.5))
                                )
                                .shadow(color: .black.opacity(0.3), radius: 30, y: 15)
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Track info - tappable
                Button {
                    if audioPlayer.isPlaying {
                        audioPlayer.pause()
                    } else {
                        audioPlayer.resume()
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(audioPlayer.currentTrack?.name ?? "Unknown")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // FIXED: Progress bar with reduced vertical margins
                VStack(spacing: 6) { // FIXED: Reduced from 8
                    Slider(
                        value: isSeeking ? $seekValue : Binding(
                            get: { audioPlayer.currentTime },
                            set: { _ in }
                        ),
                        in: 0...max(audioPlayer.duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                audioPlayer.seek(to: seekValue)
                            } else {
                                seekValue = audioPlayer.currentTime
                            }
                        }
                    )
                    .accentColor(.white)
                    
                    HStack {
                        Text(formatTime(isSeeking ? seekValue : audioPlayer.currentTime))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        Spacer()
                        
                        Text(formatTime(audioPlayer.duration))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8) // FIXED: Reduced vertical padding
                
                Spacer()
                
                // FIXED: Playback controls with more padding from edges
                HStack(spacing: 40) {
                    Button {
                        audioPlayer.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44) // FIXED: Larger tap target
                    
                    RewindButton(audioPlayer: audioPlayer, isHolding: $isHoldingRewind)
                        .frame(width: 44, height: 44) // FIXED: Larger tap target
                    
                    Button {
                        if audioPlayer.isPlaying {
                            audioPlayer.pause()
                        } else {
                            audioPlayer.resume()
                        }
                    } label: {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.white)
                    }
                    
                    FastForwardButton(audioPlayer: audioPlayer, isHolding: $isHoldingFF)
                        .frame(width: 44, height: 44) // FIXED: Larger tap target
                    
                    Button {
                        audioPlayer.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    }
                    .frame(width: 44, height: 44) // FIXED: Larger tap target
                }
                .padding(.horizontal, 32) // FIXED: More padding from edges
                .padding(.bottom, 16)
                
                // Volume control
                VStack(spacing: 8) {
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
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            updateBackgroundImage()
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
        
        // Get thumbnail path manually
        let thumbnailsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
        let filename = track.url.lastPathComponent
        let thumbnailPath = thumbnailsDir.appendingPathComponent("\(filename).jpg")
        
        guard FileManager.default.fileExists(atPath: thumbnailPath.path),
              let originalImage = UIImage(contentsOfFile: thumbnailPath.path) else {
            backgroundImage = nil
            return
        }
        
        // Crop to screen aspect ratio
        let screenAspect = UIScreen.main.bounds.width / UIScreen.main.bounds.height
        let imageAspect = originalImage.size.width / originalImage.size.height
        
        var cropRect: CGRect
        if imageAspect > screenAspect {
            // Image is wider - crop sides
            let newWidth = originalImage.size.height * screenAspect
            let x = (originalImage.size.width - newWidth) / 2
            cropRect = CGRect(x: x, y: 0, width: newWidth, height: originalImage.size.height)
        } else {
            // Image is taller - crop top/bottom
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
}

struct VolumeSlider: UIViewRepresentable {
    class Coordinator: NSObject {
        var parent: VolumeSlider
        
        init(_ parent: VolumeSlider) {
            self.parent = parent
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        volumeView.setVolumeThumbImage(UIImage(), for: .normal)
        
        // Find and configure the slider
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.minimumTrackTintColor = .white
                slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
                slider.isContinuous = true
                
                // Create custom thumb image for better visibility
                let thumbSize: CGFloat = 14
                let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
                    UIColor.white.setFill()
                    let rect = CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize)
                    context.cgContext.fillEllipse(in: rect)
                    
                    // Add shadow for better visibility
                    context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
                }
                slider.setThumbImage(thumbImage, for: .normal)
                slider.setThumbImage(thumbImage, for: .highlighted)
            }
        }
        
        return volumeView
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

// MARK: - Download Banner with FIXED animation (song name with dots)
struct DownloadBanner: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var dotCount = 1
    
    var body: some View {
        VStack(spacing: 8) {
            ForEach(downloadManager.activeDownloads, id: \.id) { download in
                HStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    // FIXED: Show song name with animated dots
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
        .onAppear {
            startDotAnimation()
        }
    }
    
    private func startDotAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            dotCount = (dotCount % 3) + 1
        }
    }
}