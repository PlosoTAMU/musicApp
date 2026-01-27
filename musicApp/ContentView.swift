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
                
                // Download banner
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
    @State private var localSeekPosition: Double = 0 // FIXED: Separate state for slider during seeking
    @State private var showPlaylistPicker = false
    @State private var backgroundImage: UIImage?
    
    // FIXED: Computed binding that prevents race conditions
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
    
    // Computed binding for playback speed that rounds to exact decimal values
    private var speedBinding: Binding<Double> {
        Binding(
            get: { audioPlayer.playbackSpeed },
            set: { newValue in
                // Round to 1 decimal place for exact values like 1.3
                let rounded = (newValue * 10).rounded() / 10
                audioPlayer.playbackSpeed = rounded
            }
        )
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
                
                if let thumbnailImage = getThumbnailImage(for: audioPlayer.currentTrack) {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 290, height: 290)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(color: .black.opacity(1), radius: 40, y: 12)
                        .onTapGesture {
                            if audioPlayer.isPlaying {
                                audioPlayer.pause()
                            } else {
                                audioPlayer.resume()
                            }
                        }
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
                        .shadow(color: .black.opacity(1), radius: 40, y: 12)
                        .onTapGesture {
                            if audioPlayer.isPlaying {
                                audioPlayer.pause()
                            } else {
                                audioPlayer.resume()
                            }
                        }
                }
                
                Spacer()
                
                VStack(spacing: 6) {
                    Text(audioPlayer.currentTrack?.name ?? "Unknown")
                        .font(.title)
                        .fontWeight(.bold)
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
                            // FIX: Initialize local position to current time when drag starts
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
                    // Loop button
                    Button {
                        audioPlayer.isLoopEnabled.toggle()
                    } label: {
                        Image(systemName: audioPlayer.isLoopEnabled ? "repeat.1" : "repeat")
                            .font(.system(size: 24))
                            .foregroundColor(audioPlayer.isLoopEnabled ? .green : .white.opacity(0.6))
                            .frame(width: 50, height: 50)
                    }
                    
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

// MARK: - Rewind/Forward Buttons
struct RewindButton: View {
    @ObservedObject var audioPlayer: AudioPlayerManager
    @State private var isLongPressing = false
    @State private var pressTimer: Timer?
    @State private var rewindTimer: Timer? // New timer for the loop
    
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
                            // 1. Wait 0.4s to detect a hold
                            pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                isLongPressing = true
                                
                                // 2. Start the Rewind Loop (Simulate 2x-3x rewind)
                                rewindTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                                    // Move back 0.5s every 0.2s
                                    audioPlayer.skip(seconds: -0.5)
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        // Clean up all timers
                        pressTimer?.invalidate()
                        pressTimer = nil
                        
                        rewindTimer?.invalidate()
                        rewindTimer = nil
                        
                        if isLongPressing {
                            isLongPressing = false
                            // Loop stopped, audio continues from new spot naturally
                        } else {
                            // Was a tap: Perform single Skip
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
                .aspectRatio(contentMode: .fit)
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressTimer == nil {
                            pressTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                                isLongPressing = true
                                audioPlayer.playbackSpeed = 2.0 // Start Fast Forwarding
                            }
                        }
                    }
                    .onEnded { _ in
                        pressTimer?.invalidate()
                        pressTimer = nil
                        
                        if isLongPressing {
                            // Was holding: Restore saved speed
                            audioPlayer.playbackSpeed = audioPlayer.savedPlaybackSpeed
                            isLongPressing = false
                        } else {
                            // Was a tap: Perform Skip
                            audioPlayer.skip(seconds: 10)
                        }
                    }
            )
    }
}

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
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                dotCount = (dotCount % 3) + 1
            }
        }
    }
}