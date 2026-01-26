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
            
            VStack(spacing: 0) {
                Spacer()
                
                // Download banner - properly positioned
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
        }
        .sheet(isPresented: $showFolderPicker) {
            FolderPicker(downloadManager: downloadManager)
        }
        .sheet(isPresented: $showYouTubeDownload) {
            YouTubeDownloadView(downloadManager: downloadManager)
        }
    }
}

// MARK: - Mini Player Bar
struct MiniPlayerBar: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var showNowPlaying: Bool
    
    var body: some View {
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
        .padding(.bottom, 49)
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
    @State private var showPlaylistPicker = false
    @State private var isHoldingRewind = false
    @State private var isHoldingFF = false
    @State private var backgroundImage: UIImage?
    
    var body: some View {
        ZStack {
            // Blurred background
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
            
            VStack(spacing: 8) {
                // Top bar
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
                .padding(.horizontal, 28)
                .padding(.top, 20)
                
                Spacer()
                
                // Album artwork
                if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 320, height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(0.5), radius: 25, y: 12)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(
                            colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 320, height: 320)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundColor(.white.opacity(0.5))
                        )
                        .shadow(color: .black.opacity(0.3), radius: 25, y: 12)
                }
                
                Spacer()
                
                // Track info
                VStack(spacing: 6) {
                    Text(audioPlayer.currentTrack?.name ?? "Unknown")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Text(audioPlayer.currentTrack?.folderName ?? "Unknown Album")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Progress bar - reduced vertical spacing
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { isSeeking ? seekValue : audioPlayer.currentTime },
                            set: { newValue in
                                seekValue = newValue
                                if isSeeking {
                                    audioPlayer.seek(to: newValue)
                                }
                            }
                        ),
                        in: 0...max(audioPlayer.duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if editing {
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
                .padding(.vertical, 4)
                
                // Playback controls
                HStack(spacing: 16) {
                    Button {
                        audioPlayer.previous()
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                    }
                    
                    RewindButton(audioPlayer: audioPlayer, isHolding: $isHoldingRewind)
                    
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
                    
                    FastForwardButton(audioPlayer: audioPlayer, isHolding: $isHoldingFF)
                    
                    Button {
                        audioPlayer.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                
                // Speed & Reverb stacked
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "gauge")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .frame(width: 20)
                        
                        Slider(value: $audioPlayer.playbackSpeed, in: 0.5...2.0)
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
                .padding(.top, 12)
                
                // Volume control
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
}



// MARK: - Rewind Button
struct RewindButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    @State private var holdTimer: Timer?
    
    var body: some View {
        Button {
            // Single tap - skip back 10 seconds
            audioPlayer.skip(seconds: -10)
        } label: {
            Image("rewind")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    isHolding = true
                    startContinuousRewind()
                }
        )
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if !pressing && isHolding {
                stopContinuousRewind()
                isHolding = false
            }
        }, perform: {})
    }
    
    private func startContinuousRewind() {
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if audioPlayer.currentTime > 0 {
                let newTime = max(0, audioPlayer.currentTime - 0.5)
                audioPlayer.seek(to: newTime)
            }
        }
    }
    
    private func stopContinuousRewind() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

// MARK: - Fast Forward Button
struct FastForwardButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @Binding var isHolding: Bool
    @State private var holdTimer: Timer?
    
    var body: some View {
        Button {
            // Single tap - skip forward 10 seconds
            audioPlayer.skip(seconds: 10)
        } label: {
            Image("forward")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    isHolding = true
                    startContinuousFastForward()
                }
        )
        .onLongPressGesture(minimumDuration: 0.5, pressing: { pressing in
            if !pressing && isHolding {
                stopContinuousFastForward()
                isHolding = false
            }
        }, perform: {})
    }
    
    private func startContinuousFastForward() {
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if audioPlayer.currentTime < audioPlayer.duration {
                let newTime = min(audioPlayer.duration, audioPlayer.currentTime + 0.5)
                audioPlayer.seek(to: newTime)
            }
        }
    }
    
    private func stopContinuousFastForward() {
        holdTimer?.invalidate()
        holdTimer = nil
    }
}

// MARK: - Volume Slider
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        volumeView.showsRouteButton = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                slider.minimumTrackTintColor = .white
                slider.maximumTrackTintColor = .white.withAlphaComponent(0.3)
                slider.isContinuous = true
                
                let thumbSize: CGFloat = 14
                let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize)).image { context in
                    UIColor.white.setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: thumbSize, height: thumbSize))
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

// MARK: - Download Banner
struct DownloadBanner: View {
    @ObservedObject var downloadManager: DownloadManager
    @State private var dotCount = 1
    
    var body: some View {
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